import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_dependencies.dart';
import 'features/photos/services/photo_saver.dart';
import 'core/errors/app_failure.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/ornaments.dart';
import 'features/access/screens/passcode_screen.dart';
import 'features/access/widgets/app_lock.dart';
import 'features/notes/screens/home_screen.dart';

class LetterApp extends StatelessWidget {
  const LetterApp({super.key, required this.dependencies, this.lockAfter = const Duration(minutes: 2)});

  final AppDependencies dependencies;

  /// How long the app can be away before it asks to be unlocked again.
  final Duration lockAfter;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // On phones the app is disguised as Threads; the public website isn't
      // (a Threads look-alike with a login box would read as phishing).
      title: kIsWeb ? 'Our Diary' : 'Threads',
      debugShowCheckedModeBanner: false,
      // Follows the phone: cream and pink in light mode, black in dark mode.
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        // Status bar icons that stay visible on screens without an app bar.
        value:
            (Theme.of(context).brightness == Brightness.light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light)
                .copyWith(statusBarColor: Colors.transparent),
        child: PhotoSaverScope(
          saver: dependencies.photoSaver,
          child: AppLock(dependencies: dependencies, lockAfter: lockAfter, child: child!),
        ),
      ),
      home: _StartGate(dependencies: dependencies),
    );
  }
}

/// Opens straight to the notes when a session exists (Supabase restores it
/// before the app starts); otherwise asks for the passcode.
class _StartGate extends StatelessWidget {
  const _StartGate({required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return dependencies.authSession.userId != null
        ? HomeScreen(dependencies: dependencies)
        : PasscodeScreen(dependencies: dependencies);
  }
}

/// Shown instead of the app when Supabase settings were not compiled in.
class ConfigurationErrorApp extends StatelessWidget {
  const ConfigurationErrorApp({super.key, this.debugDetail});

  /// Only displayed in debug builds, to help the developer.
  final String? debugDetail;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: SafeArea(
          child: CenteredMessage(
            icon: Icons.favorite_border_rounded,
            message: kDebugMode && debugDetail != null
                ? '${const ConfigurationMissing().message}\n\n$debugDetail'
                : const ConfigurationMissing().message,
          ),
        ),
      ),
    );
  }
}
