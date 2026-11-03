import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'photo_cache.dart';

PhotoCache createPhotoCache() => FilePhotoCache();

/// Files in the app's private cache folder (other apps can't read it, and
/// Android may clear it when space runs low). Kept under [maxBytes]: the
/// oldest photos are dropped first.
class FilePhotoCache implements PhotoCache {
  FilePhotoCache({this.maxBytes = 200 * 1024 * 1024, Future<Directory> Function()? baseDirectory})
    : _base = baseDirectory ?? getApplicationCacheDirectory;

  final int maxBytes;
  final Future<Directory> Function() _base;
  late final Future<Directory> _dir = _open();

  Future<Directory> _open() async {
    final dir = Directory('${(await _base()).path}/photos');
    await dir.create(recursive: true);
    // Trimmed once per start, in the background.
    _trim(dir).ignore();
    return dir;
  }

  Future<File> _file(String key) async => File('${(await _dir).path}/${key.replaceAll(RegExp(r'[^\w.-]'), '_')}');

  @override
  Future<Uint8List?> read(String key) async {
    try {
      final file = await _file(key);
      return await file.exists() ? await file.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    try {
      final file = await _file(key);
      // Written whole, then renamed, so a half-written photo is never read.
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } catch (_) {}
  }

  @override
  Future<void> remove(String key) async {
    try {
      final file = await _file(key);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _trim(Directory dir) async {
    try {
      final files = <(File, FileStat)>[
        await for (final entity in dir.list())
          if (entity is File) (entity, await entity.stat()),
      ]..sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      var total = files.fold<int>(0, (sum, f) => sum + f.$2.size);
      for (final (file, stat) in files) {
        if (total <= maxBytes) break;
        await file.delete();
        total -= stat.size;
      }
    } catch (_) {}
  }
}
