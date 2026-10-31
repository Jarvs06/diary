import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/backend_client.dart';
import '../models/photo.dart';

abstract interface class PhotosRepository {
  /// The photos of one entry, oldest first.
  Future<List<NotePhoto>> fetchPhotos(String noteId);

  /// The photos of several entries at once (for the feed), by entry id.
  Future<Map<String, List<NotePhoto>>> fetchPhotosFor(List<String> noteIds);

  /// Uploads [photo] and attaches it to the entry. Retrying with the same
  /// [id] never adds it twice.
  Future<NotePhoto> addPhoto({
    required String id,
    required String noteId,
    required PickedPhoto photo,
  });

  /// Detaches the photo and deletes its file.
  Future<void> removePhoto(NotePhoto photo);

  /// Deletes photo files whose entry was deleted. Best effort: a file left
  /// behind can't be seen by anyone, so failures are ignored.
  Future<void> removeFiles(List<String> storagePaths);

  /// The image bytes for a saved photo (cached; photo files never change).
  Future<Uint8List> loadPhoto(String storagePath);
}

class SupabasePhotosRepository implements PhotosRepository {
  SupabasePhotosRepository(this._client, {this.timeout = const Duration(seconds: 20)});

  static const bucket = 'diary-images';
  static const _cacheSize = 30;

  final SupabaseClient _client;
  final Duration timeout;
  // Insertion-ordered, so the first key is the least recently used.
  final _cache = <String, Future<Uint8List>>{};

  StorageFileApi get _files => _client.storage.from(bucket);

  @override
  Future<List<NotePhoto>> fetchPhotos(String noteId) => _guard(() async {
        final rows = await _client
            .from('note_images')
            .select(NotePhoto.columns)
            .eq('note_id', noteId)
            .order('created_at')
            .timeout(timeout);
        return rows.map(NotePhoto.fromJson).toList();
      });

  @override
  Future<Map<String, List<NotePhoto>>> fetchPhotosFor(List<String> noteIds) => _guard(() async {
        if (noteIds.isEmpty) return const {};
        final rows = await _client
            .from('note_images')
            .select(NotePhoto.columns)
            .inFilter('note_id', noteIds)
            .order('created_at')
            .timeout(timeout);
        final byNote = <String, List<NotePhoto>>{};
        for (final photo in rows.map(NotePhoto.fromJson)) {
          (byNote[photo.noteId] ??= []).add(photo);
        }
        return byNote;
      });

  @override
  Future<NotePhoto> addPhoto({
    required String id,
    required String noteId,
    required PickedPhoto photo,
  }) =>
      _guard(() async {
        final path = '$noteId/$id.${photo.extension}';
        try {
          await _files
              .uploadBinary(
                path,
                photo.bytes,
                fileOptions: FileOptions(contentType: photo.contentType, upsert: false),
              )
              .timeout(const Duration(minutes: 2));
        } on StorageException catch (e) {
          // Uploaded by an earlier attempt whose response was lost.
          if (e.statusCode != '409' && e.error != 'Duplicate') rethrow;
        }
        try {
          final row = await _client
              .from('note_images')
              .insert({'id': id, 'note_id': noteId, 'storage_path': path})
              .select(NotePhoto.columns)
              .single()
              .timeout(timeout);
          return NotePhoto.fromJson(row);
        } on PostgrestException catch (e) {
          if (e.code != '23505') rethrow;
          final row = await _client
              .from('note_images')
              .select(NotePhoto.columns)
              .eq('id', id)
              .single()
              .timeout(timeout);
          return NotePhoto.fromJson(row);
        }
      });

  @override
  Future<void> removePhoto(NotePhoto photo) => _guard(() async {
        await _client.from('note_images').delete().eq('id', photo.id).timeout(timeout);
        _cache.remove(photo.storagePath);
        // Once the row is gone nobody else can see the file, so a failed
        // cleanup here only leaves an invisible orphan behind.
        try {
          await _files.remove([photo.storagePath]).timeout(timeout);
        } catch (_) {}
      });

  @override
  Future<void> removeFiles(List<String> storagePaths) async {
    if (storagePaths.isEmpty) return;
    storagePaths.forEach(_cache.remove);
    try {
      await _files.remove(storagePaths).timeout(timeout);
    } catch (_) {}
  }

  @override
  Future<Uint8List> loadPhoto(String storagePath) {
    final cached = _cache.remove(storagePath);
    if (cached != null) return _cache[storagePath] = cached;

    final future = _guard(() => _files.download(storagePath).timeout(const Duration(minutes: 1)));
    _cache[storagePath] = future;
    if (_cache.length > _cacheSize) _cache.remove(_cache.keys.first);
    // A failed download isn't cached, so it can be retried.
    future.catchError((Object _) {
      if (identical(_cache[storagePath], future)) _cache.remove(storagePath);
      return Uint8List(0);
    });
    return future;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      throw failureFromData(e);
    }
  }
}
