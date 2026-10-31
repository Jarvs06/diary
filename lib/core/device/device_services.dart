import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// The phone's own lock (fingerprint, face, PIN or pattern), used as the
/// app lock.
abstract interface class ScreenLock {
  /// False when the phone has no screen lock set up.
  Future<bool> isAvailable();

  /// Shows the system prompt. True when the person unlocked.
  Future<bool> unlock();
}

class DeviceScreenLock implements ScreenLock {
  final _auth = LocalAuthentication();

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

/// The web version has no access to the phone's lock.
class NoScreenLock implements ScreenLock {
  const NoScreenLock();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> unlock() async => true;
}
