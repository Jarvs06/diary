import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum ActivityKind { post, reply, like }

/// Something the other person did that this phone hasn't announced yet:
/// shared an entry, replied, or liked one of your entries.
class NewActivity {
  const NewActivity({
    required this.kind,
    required this.key,
    required this.noteId,
    required this.actorName,
    required this.text,
    required this.at,
  });

  final ActivityKind kind;

  /// Unique per activity (the entry, reply or like), so a repeat replaces
  /// the earlier notification instead of stacking.
  final String key;

  /// The entry to open when the notification is tapped.
  final String noteId;
  final String actorName;

  /// The entry's title or text, or the reply's text.
  final String text;
  final DateTime at;

  /// [text]'s first line, kept short.
  String get preview {
    final line = text.trim().split('\n').first;
    return line.length <= 100 ? line : '${line.substring(0, 99)}…';
  }

  String get title => switch (kind) {
        ActivityKind.post => '$actorName shared a new entry',
        ActivityKind.reply => '$actorName replied',
        ActivityKind.like => '$actorName liked your entry',
      };

  String get body => preview.isNotEmpty ? preview : (kind == ActivityKind.post ? 'Photos' : 'Your entry');
}

/// Phone notifications for what the other person does.
///
/// "Seen" is the time of the newest activity already on screen or already
/// announced; it's stored on the phone so the app and the background check
/// (see background_check.dart) never announce the same thing twice.
abstract interface class PostNotifications {
  /// Entry ids from notifications tapped while the app is running.
  Stream<String> get taps;

  /// The entry whose notification opened the app, if any. Returned once.
  Future<String?> takeLaunchNoteId();

  /// Asks for permission to notify (Android 13+); a no-op where it's not needed.
  Future<void> requestPermission();

  Future<DateTime?> lastSeen();

  /// Moves "seen" forward to [at]; never backwards.
  Future<void> markSeen(DateTime at);

  Future<void> announce(List<NewActivity> activity);
}

class DevicePostNotifications implements PostNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<String>.broadcast();
  bool _launchTaken = false;

  static const _storage = FlutterSecureStorage();
  static const _seenKey = 'last_seen_post_at';
  static const _icon = 'ic_stat_notify';

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'new_posts',
      'New posts',
      channelDescription: 'New entries, replies and likes from the other person',
      importance: Importance.high,
      priority: Priority.high,
      icon: _icon,
      color: Color(0xFFFFA6C9),
      // The lock screen only says there's something new, not what it says.
      visibility: NotificationVisibility.private,
    ),
  );

  Future<void> init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings(_icon)),
      onDidReceiveNotificationResponse: (response) {
        final id = response.payload;
        if (id != null && id.isNotEmpty) _taps.add(id);
      },
    );
  }

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> takeLaunchNoteId() async {
    if (_launchTaken) return null;
    _launchTaken = true;
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch == null || !launch.didNotificationLaunchApp) return null;
    final id = launch.notificationResponse?.payload;
    return id == null || id.isEmpty ? null : id;
  }

  @override
  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  @override
  Future<DateTime?> lastSeen() async {
    try {
      return DateTime.tryParse(await _storage.read(key: _seenKey) ?? '');
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> markSeen(DateTime at) async {
    final current = await lastSeen();
    if (current != null && !at.isAfter(current)) return;
    try {
      await _storage.write(key: _seenKey, value: at.toUtc().toIso8601String());
    } on Exception {
      // Worst case an entry is announced twice.
    }
  }

  @override
  Future<void> announce(List<NewActivity> activity) async {
    for (final a in activity.take(6)) {
      await _plugin.show(
        id: a.key.hashCode,
        title: a.title,
        body: a.body,
        notificationDetails: _details,
        payload: a.noteId,
      );
    }
  }
}

/// The web version: no phone notifications (browsers on iPhone don't get them
/// without a push server), so nothing is shown and taps never happen.
class NoPostNotifications implements PostNotifications {
  const NoPostNotifications();

  @override
  Stream<String> get taps => const Stream.empty();

  @override
  Future<String?> takeLaunchNoteId() async => null;

  @override
  Future<void> requestPermission() async {}

  @override
  Future<DateTime?> lastSeen() async => null;

  @override
  Future<void> markSeen(DateTime at) async {}

  @override
  Future<void> announce(List<NewActivity> activity) async {}
}
