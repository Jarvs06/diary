import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Something changed on the server that the other person may have caused.
class SyncEvent {
  const SyncEvent({required this.table, this.noteId});

  /// 'notes', 'replies', 'note_images' or 'note_likes'.
  final String table;

  /// The affected note, when known.
  final String? noteId;
}

/// Pushes change notifications from Supabase Realtime. Realtime applies the
/// same RLS policies as normal queries, so drafts are never broadcast to the
/// other person. If Realtime is unavailable the app still refreshes on resume
/// and on pull-to-refresh.
abstract interface class SyncService {
  Stream<SyncEvent> get events;
  void start();
  Future<void> stop();
}

class SupabaseSyncService implements SyncService {
  SupabaseSyncService(this._client);

  final SupabaseClient _client;
  final _events = StreamController<SyncEvent>.broadcast();
  RealtimeChannel? _channel;

  @override
  Stream<SyncEvent> get events => _events.stream;

  @override
  void start() {
    if (_channel != null) return;
    _channel = _client
        .channel('notes-sync')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notes',
          callback: (payload) =>
              _events.add(SyncEvent(table: 'notes', noteId: payload.newRecord['id'] as String?)),
        )
        .onPostgresChanges(
          // New, edited and deleted replies. Deletes carry only the id, so
          // the note may be unknown.
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'replies',
          callback: (payload) => _events.add(
            SyncEvent(
              table: 'replies',
              noteId: (payload.newRecord['note_id'] ?? payload.oldRecord['note_id']) as String?,
            ),
          ),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'note_images',
          // Deletes carry only the id, so the note may be unknown.
          callback: (payload) => _events.add(
            SyncEvent(
              table: 'note_images',
              noteId: (payload.newRecord['note_id'] ?? payload.oldRecord['note_id']) as String?,
            ),
          ),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'note_likes',
          callback: (payload) => _events.add(
            SyncEvent(
              table: 'note_likes',
              noteId: (payload.newRecord['note_id'] ?? payload.oldRecord['note_id']) as String?,
            ),
          ),
        )
        .subscribe();
  }

  @override
  Future<void> stop() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client.removeChannel(channel);
  }
}
