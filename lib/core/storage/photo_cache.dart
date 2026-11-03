import 'dart:typed_data';

import 'photo_cache_io.dart' if (dart.library.js_interop) 'photo_cache_web.dart' as impl;

/// Photos kept on the phone once downloaded, so they show instantly and
/// without a connection. Photo files never change (each has its own id), so
/// a saved copy is always current.
abstract interface class PhotoCache {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List bytes);
  Future<void> remove(String key);
}

/// The phone's cache folder on Android; nothing in the browser.
PhotoCache createPhotoCache() => impl.createPhotoCache();

/// Keeps nothing (the browser, and tests).
class NoPhotoCache implements PhotoCache {
  const NoPhotoCache();

  @override
  Future<Uint8List?> read(String key) async => null;

  @override
  Future<void> write(String key, Uint8List bytes) async {}

  @override
  Future<void> remove(String key) async {}
}
