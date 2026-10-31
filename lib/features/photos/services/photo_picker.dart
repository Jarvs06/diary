import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/errors/app_failure.dart';
import '../models/photo.dart';

enum PhotoSource { gallery, camera }

/// Lets the person choose photos from the phone.
abstract interface class PhotoPicker {
  /// Up to [limit] photos, resized for upload. Returns an empty list if the
  /// person cancels. Throws [InvalidContent] for an unsupported or huge file.
  Future<List<PickedPhoto>> pick(PhotoSource source, {required int limit});
}

class DevicePhotoPicker implements PhotoPicker {
  DevicePhotoPicker([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  // Big enough to look sharp full-screen, small enough to upload quickly.
  static const _maxSide = 2048.0;
  static const _quality = 85;

  @override
  Future<List<PickedPhoto>> pick(PhotoSource source, {required int limit}) async {
    if (limit < 1) return const [];
    final List<XFile> files;
    try {
      if (source == PhotoSource.camera || limit == 1) {
        final file = await _picker.pickImage(
          source: source == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery,
          maxWidth: _maxSide,
          maxHeight: _maxSide,
          imageQuality: _quality,
          requestFullMetadata: false,
        );
        files = [?file];
      } else {
        files = await _picker.pickMultiImage(
          limit: limit,
          maxWidth: _maxSide,
          maxHeight: _maxSide,
          imageQuality: _quality,
          requestFullMetadata: false,
        );
      }
    } on PlatformException catch (e) {
      throw InvalidContent(e.code == 'camera_access_denied'
          ? 'Camera access is turned off for this app.'
          : "I couldn't open your photos. Please try again.");
    }

    final photos = <PickedPhoto>[];
    for (final file in files.take(limit)) {
      final bytes = await file.readAsBytes();
      final extension = PickedPhoto.detectExtension(bytes);
      if (extension == null) {
        throw const InvalidContent("That photo's format isn't supported. Try a JPG or PNG.");
      }
      if (bytes.length > PickedPhoto.maxBytes) {
        throw const InvalidContent('That photo is too large.');
      }
      photos.add(PickedPhoto(bytes, extension));
    }
    return photos;
  }
}
