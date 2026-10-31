import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/backend_client.dart';
import '../models/participant.dart';

abstract interface class ParticipantsRepository {
  /// Both participants. RLS returns nothing to anyone else.
  Future<List<Participant>> fetchAll();
}

class SupabaseParticipantsRepository implements ParticipantsRepository {
  SupabaseParticipantsRepository(this._client, {this.timeout = const Duration(seconds: 20)});

  final SupabaseClient _client;
  final Duration timeout;

  @override
  Future<List<Participant>> fetchAll() async {
    try {
      final rows = await _client
          .from('participants')
          .select('id, participant_key, display_name')
          .timeout(timeout);
      return rows.map(Participant.fromJson).toList();
    } catch (e) {
      throw failureFromData(e);
    }
  }
}

