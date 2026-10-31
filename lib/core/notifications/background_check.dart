import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../auth/auth_session.dart';
import '../config/app_config.dart';
import 'activity_check.dart';
import 'post_notifications.dart';

const _taskName = 'check-new-posts';

/// Asks Android to run [checkForNewPosts] about every 15 minutes (the
/// shortest interval Android allows), even while the app is closed.
Future<void> scheduleBackgroundChecks() async {
  await Workmanager().initialize(backgroundCheckDispatcher);
  await Workmanager().registerPeriodicTask(
    _taskName,
    _taskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

/// Runs in a separate background isolate started by Android.
@pragma('vm:entry-point')
void backgroundCheckDispatcher() {
  Workmanager().executeTask((task, _) async {
    try {
      await checkForNewPosts();
    } catch (_) {
      // Offline, signed out, etc.: try again next time.
    }
    return true;
  });
}

/// Announces the other person's new entries, replies and likes since this
/// phone last looked. Uses the signed-in session from secure storage; does
/// nothing when signed out (after Lock).
Future<void> checkForNewPosts() async {
  final config = AppConfig.fromEnvironment();
  await Supabase.initialize(
    url: config.supabaseUrl,
    publishableKey: config.supabasePublishableKey,
    debug: false,
    authOptions: const FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
  );
  final client = Supabase.instance.client;
  if (client.auth.currentUser == null) return;

  final notifications = DevicePostNotifications();
  await notifications.init();
  await SupabaseActivityChecker(client, notifications).catchUp(announce: true);
}
