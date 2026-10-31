import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/app_dependencies.dart';
import 'core/auth/auth_session.dart';
import 'core/config/app_config.dart';
import 'core/device/device_services.dart';
import 'core/network/backend_client.dart';
import 'core/notifications/activity_check.dart';
import 'core/notifications/background_check.dart';
import 'core/notifications/post_notifications.dart';
import 'core/storage/local_store.dart';
import 'core/sync/sync_service.dart';
import 'core/updates/releases.dart';
import 'features/access/data/access_repository.dart';
import 'features/notes/data/notes_repository.dart';
import 'features/participants/data/participants_repository.dart';
import 'features/photos/data/photos_repository.dart';
import 'features/photos/services/photo_picker.dart';
import 'features/replies/data/replies_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerFontLicenses();

  final AppConfig config;
  try {
    config = AppConfig.fromEnvironment();
  } on ConfigException catch (e) {
    runApp(ConfigurationErrorApp(debugDetail: e.message));
    return;
  }

  // Started now so it overlaps with the session being restored below.
  final packageInfo = PackageInfo.fromPlatform();

  await Supabase.initialize(
    url: config.supabaseUrl,
    // The publishable key (or legacy anon key). Public by design; RLS and the
    // Edge Functions are what protect the diary.
    publishableKey: config.supabasePublishableKey,
    debug: false,
    // The session is kept in the Android Keystore-backed secure storage
    // (on the web: encrypted in the browser's local storage).
    authOptions: const FlutterAuthClientOptions(localStorage: SecureSessionStorage()),
  );

  final client = Supabase.instance.client;
  final auth = SupabaseAuthSession(client.auth);
  // The web version (GitHub Pages, e.g. on an iPhone) has no phone
  // notifications, background checks or fingerprint lock.
  final PostNotifications notifications;
  if (kIsWeb) {
    notifications = const NoPostNotifications();
  } else {
    final device = DevicePostNotifications();
    await device.init();
    notifications = device;
    // Checks for the other person's new entries while the app is closed.
    unawaited(scheduleBackgroundChecks().catchError((Object _) {}));
  }
  final package = await packageInfo;
  runApp(
    LetterApp(
      dependencies: AppDependencies(
        accessRepository: SupabaseAccessRepository(
          SupabaseBackendClient(client),
          auth,
          appKey: config.appKey,
        ),
        authSession: auth,
        participantsRepository: SupabaseParticipantsRepository(client),
        notesRepository: SupabaseNotesRepository(client),
        repliesRepository: SupabaseRepliesRepository(client),
        photosRepository: SupabasePhotosRepository(client),
        photoPicker: DevicePhotoPicker(),
        syncService: SupabaseSyncService(client),
        notifications: notifications,
        activity: SupabaseActivityChecker(client, notifications),
        localStore: const SecureLocalStore(),
        screenLock: kIsWeb ? const NoScreenLock() : DeviceScreenLock(),
        backgroundRunning: DeviceBackgroundRunning(),
        releases: SupabaseReleasesRepository(client),
        buildNumber: int.tryParse(package.buildNumber) ?? 0,
      ),
    ),
  );
}

void _registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in [
      ('Google Sans', 'assets/fonts/OFL-GoogleSans.txt'),
      ('Google Sans Flex', 'assets/fonts/OFL-GoogleSansFlex.txt'),
      ('Momo Signature', 'assets/fonts/OFL-MomoSignature.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([family], await rootBundle.loadString(file));
    }
  });
}
