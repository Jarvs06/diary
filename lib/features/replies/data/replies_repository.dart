import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/backend_client.dart';
import '../models/reply.dart';

abstract interface class RepliesRepository {
  /// Replies under a note, oldest first.
  Future<List<Reply>> fetchReplies(String noteId);

  /// Sends a reply with a device-generated [id]; retrying with the same id
  /// never creates a duplicate.
  Future<Reply> sendReply({required String id, required String noteId, required String body});

  /// Changes the text of your own reply.
  Future<Reply> editReply({required String id, required String body});

  /// Deletes your own reply. Already gone counts as done.
  Future<void> deleteReply(String id);
}

class SupabaseRepliesRepository implements RepliesRepository {
  SupabaseRepliesRepository(this._client, {this.timeout = const Duration(seconds: 20)});

  final SupabaseClient _client;
  final Duration timeout;

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
  Future<Reply> sendReply({required String id, required String noteId, required String body}) async {
    try {
      try {
        final row = await _client
            .from('replies')
            .insert({'id': id, 'note_id': noteId, 'body': body})
            .select(Reply.columns)
            .single()
            .timeout(timeout);
        return Reply.fromJson(row);
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow;
        // Saved by an earlier attempt whose response was lost.
        final row = await _client
            .from('replies')
            .select(Reply.columns)
            .eq('id', id)
            .single()
            .timeout(timeout);
        return Reply.fromJson(row);
      }
    } catch (e) {
      throw failureFromData(e);
    }
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
  Future<void> deleteReply(String id) async {
    try {
      await _client.from('replies').delete().eq('id', id).timeout(timeout);
    } catch (e) {
      throw failureFromData(e);
    }
  }
}
