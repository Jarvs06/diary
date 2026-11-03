import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/backend_client.dart';
import '../../photos/models/photo.dart';
import '../../photos/services/photo_preview.dart';
import '../models/reply.dart';

abstract interface class RepliesRepository {
  /// Replies under a note, oldest first.
  Future<List<Reply>> fetchReplies(String noteId);

  /// Replies under several notes at once (for the export), oldest first.
  Future<List<Reply>> fetchRepliesFor(List<String> noteIds);

  /// Sends a reply with a device-generated [id]; retrying with the same id
  /// never creates a duplicate. [parentId] makes it an answer to that
  /// top-level reply; [photo] is attached to it.
  Future<Reply> sendReply({
    required String id,
    required String noteId,
    required String body,
    String? parentId,
    PickedPhoto? photo,
  });

  /// Changes the text of your own reply.
  Future<Reply> editReply({required String id, required String body});

  /// Deletes your own reply (and its photo). Already gone counts as done.
  Future<void> deleteReply(Reply reply);

  /// The bytes of a reply's photo (cached; photos never change).
  Future<Uint8List> loadPhoto(String imagePath);
}

class SupabaseRepliesRepository implements RepliesRepository {
  SupabaseRepliesRepository(this._client, {this.timeout = const Duration(seconds: 20)});

  static const bucket = 'reply-images';
  static const _cacheSize = 20;

  final SupabaseClient _client;
  final Duration timeout;
  // Insertion-ordered, so the first key is the least recently used.
  final _cache = <String, Future<Uint8List>>{};

  StorageFileApi get _files => _client.storage.from(bucket);

  @override
  Future<List<Reply>> fetchReplies(String noteId) async {
    try {
      final rows = await _client
          .from('replies')
          .select(Reply.columns)
          .eq('note_id', noteId)
          .order('created_at')
          .order('id')
          .timeout(timeout);
      return rows.map(Reply.fromJson).toList();
    } catch (e) {
      throw failureFromData(e);
    }
  }

  @override
  Future<List<Reply>> fetchRepliesFor(List<String> noteIds) async {
    if (noteIds.isEmpty) return const [];
    try {
      final rows = await _client
          .from('replies')
          .select(Reply.columns)
          .inFilter('note_id', noteIds)
          .order('created_at')
          .order('id')
          .timeout(timeout);
      return rows.map(Reply.fromJson).toList();
    } catch (e) {
      throw failureFromData(e);
    }
  }

  @override
  Future<Reply> sendReply({
    required String id,
    required String noteId,
    required String body,
    String? parentId,
    PickedPhoto? photo,
  }) async {
    try {
      // Reply photos are always stored as a JPEG of a sensible size.
      Uint8List? jpeg;
      if (photo != null) {
        jpeg = await makePhotoPreview(photo.bytes, maxSide: 1600, quality: 85);
        if (jpeg == null) throw const InvalidContent("That photo couldn't be read. Try another one.");
      }
      final imagePath = jpeg == null ? null : '$id.jpg';

      Reply reply;
      try {
        final row = await _client
            .from('replies')
            .insert({'id': id, 'note_id': noteId, 'body': body, 'parent_id': ?parentId, 'image_path': ?imagePath})
            .select(Reply.columns)
            .single()
            .timeout(timeout);
        reply = Reply.fromJson(row);
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow;
        // Saved by an earlier attempt whose response was lost.
        final row = await _client.from('replies').select(Reply.columns).eq('id', id).single().timeout(timeout);
        reply = Reply.fromJson(row);
      }

      // The photo goes up once its reply exists (Storage checks that the
      // reply is yours). If it can't, the reply is taken back so it's never
      // left with a missing photo, and sending again retries both.
      if (jpeg != null && imagePath != null) {
        try {
          await _files
              .uploadBinary(imagePath, jpeg, fileOptions: const FileOptions(contentType: 'image/jpeg'))
              .timeout(const Duration(minutes: 2));
        } catch (e) {
          // Already uploaded by an earlier attempt.
          final duplicate = e is StorageException && (e.statusCode == '409' || e.error == 'Duplicate');
          if (!duplicate) {
            await _takeBack(id);
            rethrow;
          }
        }
        _cache[imagePath] = Future.value(jpeg);
      }
      return reply;
    } catch (e) {
      throw failureFromData(e);
    }
  }

  Future<void> _takeBack(String id) async {
    try {
      await _client.from('replies').delete().eq('id', id).timeout(timeout);
    } catch (_) {}
  }

  @override
  Future<Reply> editReply({required String id, required String body}) async {
    try {
      final row = await _client
          .from('replies')
          .update({'body': body})
          .eq('id', id)
          .select(Reply.columns)
          .single()
          .timeout(timeout);
      return Reply.fromJson(row);
    } catch (e) {
      throw failureFromData(e);
    }
  }

  @override
  Future<void> deleteReply(Reply reply) async {
    try {
      await _client.from('replies').delete().eq('id', reply.id).timeout(timeout);
    } catch (e) {
      throw failureFromData(e);
    }
    final path = reply.imagePath;
    if (path == null) return;
    _cache.remove(path);
    // Once the reply is gone nobody else can see the file, so a failed
    // cleanup only leaves an invisible orphan behind.
    try {
      await _files.remove([path]).timeout(timeout);
    } catch (_) {}
  }

  @override
  Future<Uint8List> loadPhoto(String imagePath) {
    final cached = _cache.remove(imagePath);
    if (cached != null) return _cache[imagePath] = cached;

    final future = _files
        .download(imagePath)
        .timeout(const Duration(minutes: 1))
        .catchError((Object e) => throw failureFromData(e));
    _cache[imagePath] = future;
    if (_cache.length > _cacheSize) _cache.remove(_cache.keys.first);
    // A failed download isn't cached, so it can be retried.
    future.catchError((Object _) {
      if (identical(_cache[imagePath], future)) _cache.remove(imagePath);
      return Uint8List(0);
    });
    return future;
  }
}
