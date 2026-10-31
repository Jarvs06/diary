import 'dart:typed_data';

/// A photo attached to a diary entry, as listed in `note_images`.
class NotePhoto {
  const NotePhoto({
    required this.id,
    required this.noteId,
    required this.authorId,
    required this.storagePath,
    required this.createdAt,
  });

  final String id;
  final String noteId;
  final String authorId;

  /// `<note id>/<photo id>.<ext>` in the private `diary-images` bucket.
  final String storagePath;
  final DateTime createdAt;

  static const columns = 'id, note_id, author_id, storage_path, created_at';

  factory NotePhoto.fromJson(Map<String, dynamic> json) => NotePhoto(
        id: json['id'] as String,
        noteId: json['note_id'] as String,
        authorId: json['author_id'] as String,
        storagePath: json['storage_path'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

/// A photo chosen on this phone, already resized, not yet uploaded.
class PickedPhoto {
  const PickedPhoto(this.bytes, this.extension);

  /// Same limit as the Storage bucket.
  static const maxBytes = 10 * 1024 * 1024;

  final Uint8List bytes;

  /// 'jpg', 'png' or 'webp'.
  final String extension;

  String get contentType => switch (extension) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };

  /// Reads the format from the file's first bytes (never trusts the name).
  /// Returns null for anything other than JPEG, PNG or WebP.
  static String? detectExtension(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'jpg';
    if (b.length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
      return 'png';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'webp';
    }
    return null;
  }
}

/// A photo in the editor: either already saved, or picked and waiting to upload.
class EditorPhoto {
  EditorPhoto.saved(NotePhoto this.saved) : id = saved.id, picked = null;
  const EditorPhoto.picked(this.id, PickedPhoto this.picked) : saved = null;

  final String id;
  final NotePhoto? saved;
  final PickedPhoto? picked;
}
