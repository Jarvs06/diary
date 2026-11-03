import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/errors/app_failure.dart';
import '../models/photo.dart';

/// Saves a photo onto the phone.
abstract interface class PhotoSaver {
  /// Throws [AppFailure] if it couldn't be saved.
  Future<void> save(Uint8List bytes);
}

/// Android: straight into the phone's Photos/Gallery. Browser: the share
/// sheet on iPhone ("Save Image"), a download on a computer.
class DevicePhotoSaver implements PhotoSaver {
  const DevicePhotoSaver();

  @override
  Future<void> save(Uint8List bytes) async {
    final extension = PickedPhoto.detectExtension(bytes) ?? 'jpg';
    final name = 'photo-${DateTime.now().millisecondsSinceEpoch}.$extension';
    if (kIsWeb) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: PickedPhoto(bytes, extension).contentType, name: name)],
          fileNameOverrides: [name],
          downloadFallbackEnabled: true,
        ),
      );
      return;
    }
    try {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        throw const InvalidContent('Allow access to your photos to save it.');
      }
      await Gal.putImageBytes(bytes, name: name);
    } on GalException {
      throw const InvalidContent("Couldn't save the photo. Please try again.");
    }
  }
}

/// Makes the [PhotoSaver] available to the full-screen photo viewer.
class PhotoSaverScope extends InheritedWidget {
  const PhotoSaverScope({super.key, required this.saver, required super.child});

  final PhotoSaver saver;

  static PhotoSaver? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PhotoSaverScope>()?.saver;

  @override
  bool updateShouldNotify(PhotoSaverScope old) => old.saver != saver;
}
