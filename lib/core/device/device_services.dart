import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../features/access/data/access_repository.dart';
import '../auth/auth_session.dart';
import '../errors/app_failure.dart';

/// The phone's own lock (fingerprint, face, PIN or pattern), used as the
/// app lock.
abstract interface class ScreenLock {
  /// False when the phone has no screen lock set up.
  Future<bool> isAvailable();

  /// Shows the system prompt. True when the person unlocked.
  Future<bool> unlock();

  /// True when unlocking means typing your app passcode (the web version)
  /// instead of the phone's own prompt.
  bool get usesPasscode;

  /// Checks [passcode] for the [usesPasscode] lock. Null when it's yours.
  Future<AppFailure?> unlockWithPasscode(String passcode);
}

class DeviceScreenLock implements ScreenLock {
  final _auth = LocalAuthentication();

  @override
  bool get usesPasscode => false;

  @override
  Future<AppFailure?> unlockWithPasscode(String passcode) async => const NotAllowed();

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> unlock() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock to continue',
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } on PlatformException {
      return false;
    }
  }
}

/// Whether Android lets the app's background check run freely. Some phones
/// (Xiaomi, Oppo, Vivo, Samsung…) stop it to save battery otherwise.
abstract interface class BackgroundRunning {
  Future<bool> isUnrestricted();

  /// Opens Android's "allow running in background" prompt.
  Future<void> askUnrestricted();
}

class DeviceBackgroundRunning implements BackgroundRunning {
  static const _channel = MethodChannel('diary/battery');

  @override
  Future<bool> isUnrestricted() async {
    try {
      return await _channel.invokeMethod<bool>('isUnrestricted') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<void> askUnrestricted() async {
    try {
      await _channel.invokeMethod<void>('askUnrestricted');
    } on PlatformException {
      // Nothing more we can do.
    }
  }
}

/// The web version can't use the phone's lock, so it asks for your app
/// passcode again. The server checks it (with the usual wrong-try limits),
/// and it must be the signed-in person's own passcode.
class PasscodeScreenLock implements ScreenLock {
  PasscodeScreenLock(this._access, this._auth);

  final AccessRepository _access;
  final AuthSession _auth;

  @override
  bool get usesPasscode => true;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> unlock() async => false;

  @override
  Future<AppFailure?> unlockWithPasscode(String passcode) async {
    try {
      final id = await _access.verifyPasscode(passcode);
      return id == _auth.userId ? null : const IncorrectPasscode();
    } on AppFailure catch (f) {
      return f;
    }
  }
}
