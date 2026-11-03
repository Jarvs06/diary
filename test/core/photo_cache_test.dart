import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secret_diary/core/storage/photo_cache_io.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('photo-cache-test'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('keeps photos between starts, and forgets removed ones', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await FilePhotoCache(baseDirectory: () async => temp).write('diary/n1/p1.jpg', bytes);

    final later = FilePhotoCache(baseDirectory: () async => temp);
    expect(await later.read('diary/n1/p1.jpg'), bytes);
    expect(await later.read('diary/n1/p2.jpg'), isNull);
    await later.remove('diary/n1/p1.jpg');
    expect(await later.read('diary/n1/p1.jpg'), isNull);
  });

  test('stays under its size limit by dropping the oldest photos', () async {
    final first = FilePhotoCache(baseDirectory: () async => temp);
    await first.write('old', Uint8List(600));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await first.write('new', Uint8List(600));

    final next = FilePhotoCache(maxBytes: 1000, baseDirectory: () async => temp);
    await next.read('x'); // opening the folder trims it
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await next.read('old'), isNull);
    expect(await next.read('new'), hasLength(600));
  });
}
