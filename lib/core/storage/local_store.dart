import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small key-value storage on the phone: the composer's unsaved text, the
/// last time the feed was opened, and a copy of the feed for offline reading.
abstract interface class LocalStore {
  Future<String?> read(String key);

  /// Writes [value], or removes the key when it's null.
  Future<void> write(String key, String? value);
}

/// Kept in the Android Keystore-backed secure storage, like the session.
class SecureLocalStore implements LocalStore {
  const SecureLocalStore();

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> write(String key, String? value) async {
    try {
      if (value == null) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
    } on Exception {
      // Nothing important is lost: these are conveniences.
    }
  }
}
