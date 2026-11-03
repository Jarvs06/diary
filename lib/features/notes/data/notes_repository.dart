import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/network/backend_client.dart';
import '../../../core/utils/dates.dart';
import '../models/note.dart';

abstract interface class NotesRepository {
  /// Published notes from both people plus your own drafts, newest activity first.
  Future<List<Note>> fetchRecents();

  /// The latest version of one note. Throws [NoteNotFound] if it's not visible.
  Future<Note> fetchNote(String id);

  /// Creates a note with a device-generated [id]; safe to retry.
  Future<Note> createNote({
    required String id,
    required String title,
    required String body,
    required NoteStatus status,
    required DateTime entryDate,
  });

  /// Saves an edit only if the server still has [expectedVersion]; otherwise
  /// throws [EditConflict] carrying the newer note.
  Future<Note> updateNote({
    required String id,
    required int expectedVersion,
    required String title,
    required String body,
    required NoteStatus status,
    required DateTime entryDate,
  });

  /// Likes or unlikes the entry as the signed-in person. Safe to repeat.
  Future<void> setLiked(String noteId, {required bool liked});

  /// Records that you've read the other person's shared entry (once).
  Future<void> markSeen(String noteId);

  /// Pins or unpins an entry on your own profile.
  Future<void> setPinned(String noteId, {required bool pinned});

  /// Deletes your own entry (with its replies, likes and photo rows).
  /// Throws [NoteNotFound] if it's already gone or isn't yours.
  Future<void> deleteNote(String id);
}

class SupabaseNotesRepository implements NotesRepository {
  SupabaseNotesRepository(this._client, {this.timeout = const Duration(seconds: 20)});

  final SupabaseClient _client;
  final Duration timeout;

  @override
  Future<List<Note>> fetchRecents() => _guard(() async {
    final rows = await _client
        .from('notes')
        .select(Note.columns)
        .order('last_activity_at', ascending: false)
        .limit(500)
        .timeout(timeout);
    return rows.map(Note.fromJson).toList();
  });

  @override
  Future<Note> fetchNote(String id) => _guard(() async {
    final row = await _client.from('notes').select(Note.columns).eq('id', id).maybeSingle().timeout(timeout);
    if (row == null) throw const NoteNotFound();
    return Note.fromJson(row);
  });

  @override
  Future<Note> createNote({
    required String id,
    required String title,
    required String body,
    required NoteStatus status,
    required DateTime entryDate,
  }) => _guard(() async {
    try {
      final row = await _client
          .from('notes')
          .insert({'id': id, 'title': title, 'body': body, 'status': status.name, 'entry_date': Dates.iso(entryDate)})
          .select(Note.columns)
          .single()
          .timeout(timeout);
      return Note.fromJson(row);
    } on PostgrestException catch (e) {
      // Already created by an earlier attempt whose response was lost.
      if (e.code == '23505') return fetchNote(id);
      rethrow;
    }
  });

  @override
  Future<Note> updateNote({
    required String id,
    required int expectedVersion,
    required String title,
    required String body,
    required NoteStatus status,
    required DateTime entryDate,
  }) => _guard(() async {
    final row = await _client
        .from('notes')
        .update({'title': title, 'body': body, 'status': status.name, 'entry_date': Dates.iso(entryDate)})
        .eq('id', id)
        .eq('version', expectedVersion)
        .select(Note.columns)
        .maybeSingle()
        .timeout(timeout);
    if (row != null) return Note.fromJson(row);

    final latest = await fetchNote(id);
    // An earlier attempt may have succeeded before its response was lost.
    if (latest.title == title &&
        latest.body == body &&
        latest.status == status &&
        latest.entryDate == Dates.dateOnly(entryDate)) {
      return latest;
    }
    throw EditConflict(latest);
  });

  @override
  Future<void> setLiked(String noteId, {required bool liked}) => _guard(() async {
    if (liked) {
      try {
        await _client.from('note_likes').insert({'note_id': noteId}).timeout(timeout);
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow; // already liked
      }
    } else {
      // RLS limits this to your own like.
      await _client.from('note_likes').delete().eq('note_id', noteId).timeout(timeout);
    }
  });

  @override
  Future<void> markSeen(String noteId) => _guard(() async {
    try {
      await _client.from('note_views').insert({'note_id': noteId}).timeout(timeout);
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow; // already seen
    }
  });

  @override
  Future<void> setPinned(String noteId, {required bool pinned}) => _guard(() async {
    if (pinned) {
      try {
        await _client.from('note_pins').insert({'note_id': noteId}).timeout(timeout);
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow; // already pinned
      }
    } else {
      // RLS limits this to your own pin.
      await _client.from('note_pins').delete().eq('note_id', noteId).timeout(timeout);
    }
  });

  @override
  Future<void> deleteNote(String id) => _guard(() async {
    final rows = await _client.from('notes').delete().eq('id', id).select('id').timeout(timeout);
    if (rows.isEmpty) throw const NoteNotFound();
  });

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      throw failureFromData(e);
    }
  }
}
