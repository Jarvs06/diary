import 'package:supabase_flutter/supabase_flutter.dart';

import 'post_notifications.dart';

/// Finds what the other person did since this phone last looked.
abstract interface class ActivityChecker {
  /// With [announce], shows notifications for the other person's new
  /// entries, replies and likes on your entries since the last check.
  /// Without it (the app is on screen), just marks everything up to now as
  /// seen.
  Future<void> catchUp({required bool announce});
}

class SupabaseActivityChecker implements ActivityChecker {
  SupabaseActivityChecker(this._client, this._notifications, {this.timeout = const Duration(seconds: 20)});

  final SupabaseClient _client;
  final PostNotifications _notifications;
  final Duration timeout;

  @override
  Future<void> catchUp({required bool announce}) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return;
    final seen = await _notifications.lastSeen();
    if (!announce || seen == null) {
      // On screen, or the first check ever: start from now.
      await _notifications.markSeen(DateTime.now().toUtc());
      return;
    }
    final since = seen.toUtc().toIso8601String();

    final results = await Future.wait([
      _client
          .from('notes')
          .select('id, author_id, title, body, published_at')
          .eq('status', 'published')
          .neq('author_id', me)
          .gt('published_at', since)
          .order('published_at')
          .limit(10),
      _client
          .from('replies')
          .select('id, note_id, author_id, body, created_at')
          .neq('author_id', me)
          .gt('created_at', since)
          .order('created_at')
          .limit(10),
      // Likes from the other person on your own entries.
      _client
          .from('note_likes')
          .select('note_id, user_id, created_at, notes!inner(author_id, title, body)')
          .neq('user_id', me)
          .eq('notes.author_id', me)
          .gt('created_at', since)
          .order('created_at')
          .limit(10),
      _client.from('participants').select('id, display_name'),
    ]).timeout(timeout);

    final names = {for (final p in results[3]) p['id'] as String: (p['display_name'] as String?) ?? 'Someone'};
    String name(Object? id) => names[id] ?? 'Someone';
    String entryText(Map<String, dynamic> n) {
      final title = (n['title'] as String? ?? '').trim();
      return title.isNotEmpty ? title : n['body'] as String? ?? '';
    }

    final activity = <NewActivity>[
      for (final r in results[0])
        NewActivity(
          kind: ActivityKind.post,
          key: 'post-${r['id']}',
          noteId: r['id'] as String,
          actorName: name(r['author_id']),
          text: entryText(r),
          at: DateTime.parse(r['published_at'] as String),
        ),
      for (final r in results[1])
        NewActivity(
          kind: ActivityKind.reply,
          key: 'reply-${r['id']}',
          noteId: r['note_id'] as String,
          actorName: name(r['author_id']),
          text: r['body'] as String? ?? '',
          at: DateTime.parse(r['created_at'] as String),
        ),
      for (final r in results[2])
        NewActivity(
          kind: ActivityKind.like,
          key: 'like-${r['note_id']}-${r['user_id']}',
          noteId: r['note_id'] as String,
          actorName: name(r['user_id']),
          text: entryText(r['notes'] as Map<String, dynamic>),
          at: DateTime.parse(r['created_at'] as String),
        ),
    ]..sort((a, b) => a.at.compareTo(b.at));
    if (activity.isEmpty) return;

    await _notifications.announce(activity);
    await _notifications.markSeen(activity.last.at);
  }
}
