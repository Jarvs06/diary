import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:secret_diary/features/photos/models/photo.dart';
import 'package:secret_diary/features/photos/services/photo_preview.dart';

void main() {
  test('a preview sits next to its photo as .thumb.jpg', () {
    expect(NotePhoto.previewPathOf('n1/p1.jpg'), 'n1/p1.thumb.jpg');
    expect(NotePhoto.previewPathOf('n1/p1.png'), 'n1/p1.thumb.jpg');
    expect(NotePhoto.previewPathOf('n1/p1.webp'), 'n1/p1.thumb.jpg');
  });

  testWidgets('a large photo becomes a JPEG at most 900 px on its longest side', (tester) async {
    final big = Uint8List.fromList(img.encodeJpg(img.Image(width: 2000, height: 1500), quality: 90));
    final preview = await tester.runAsync(() => makePhotoPreview(big));
    expect(preview, isNotNull);
    final decoded = img.decodeJpg(preview!)!;
    expect(decoded.width, 900);
    expect(decoded.height, 675);
    expect(preview.length, lessThan(big.length));
  });

  testWidgets('unreadable bytes give no preview', (tester) async {
    final preview = await tester.runAsync(() => makePhotoPreview(Uint8List.fromList([1, 2, 3])));
    expect(preview, isNull);
  });
}
