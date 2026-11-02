import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// A small JPEG copy of a photo (longest side at most [maxSide]) for the
/// feed. Returns null if the photo can't be read; the feed then shows the
/// full photo instead.
Future<Uint8List?> makePhotoPreview(Uint8List bytes, {int maxSide = 900, int quality = 80}) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = maxSide / (descriptor.width > descriptor.height ? descriptor.width : descriptor.height);
    final codec = await descriptor.instantiateCodec(
      targetWidth: scale < 1 ? (descriptor.width * scale).round() : descriptor.width,
      targetHeight: scale < 1 ? (descriptor.height * scale).round() : descriptor.height,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    final height = image.height;
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (rgba == null) return null;
    final decoded = img.Image.fromBytes(width: width, height: height, bytes: rgba.buffer, numChannels: 4);
    return Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
  } catch (_) {
    return null;
  }
}
