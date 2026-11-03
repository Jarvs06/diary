import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/utils/dates.dart';
import '../notes/models/note.dart';
import '../participants/models/participant.dart';
import '../photos/data/photos_repository.dart';
import '../photos/models/photo.dart';
import '../replies/data/replies_repository.dart';

/// Builds a .zip with everything you can see: `diary.html` to read in any
/// browser, `diary.json` with all the data, and the full photos in `photos/`.
class DiaryExporter {
  DiaryExporter({required this.replies, required this.photos});

  final RepliesRepository replies;
  final PhotosRepository photos;

  /// [onProgress] gets (photos done, photos in total).
  Future<Uint8List> build({
    required List<Note> notes,
    required Map<String, Participant> people,
    void Function(int done, int total)? onProgress,
    DateTime? now,
  }) async {
    final sorted = [...notes]..sort((a, b) => b.entryDate.compareTo(a.entryDate));
    final ids = sorted.map((n) => n.id).toList();
    final allReplies = await replies.fetchRepliesFor(ids);
    final photoMap = await photos.fetchPhotosFor(ids);
    String name(String id) => people[id]?.displayName ?? 'Someone';

    final archive = Archive();
    final photoFiles = <String, List<String>>{};
    final replyPhotos = allReplies.where((r) => r.imagePath != null).toList();
    final total = photoMap.values.fold<int>(replyPhotos.length, (sum, list) => sum + list.length);
    var done = 0;
    onProgress?.call(0, total);
    for (final note in sorted) {
      for (final photo in photoMap[note.id] ?? const <NotePhoto>[]) {
        final file = 'photos/${note.id}-${photo.storagePath.split('/').last}';
        archive.addFile(ArchiveFile.bytes(file, await photos.loadPhoto(photo.storagePath)));
        (photoFiles[note.id] ??= []).add(file);
        onProgress?.call(++done, total);
      }
    }
    final replyPhotoFiles = <String, String>{};
    for (final reply in replyPhotos) {
      final file = 'photos/replies/${reply.imagePath}';
      archive.addFile(ArchiveFile.bytes(file, await replies.loadPhoto(reply.imagePath!)));
      replyPhotoFiles[reply.id] = file;
      onProgress?.call(++done, total);
    }

    final posts = [
      for (final n in sorted)
        {
          'id': n.id,
          'author': name(n.authorId),
          'status': n.status.name,
          'day': Dates.iso(n.entryDate),
          'posted_at': n.postedAt.toIso8601String(),
          'title': n.title,
          'body': n.body,
          'liked_by': [for (final id in n.likedBy) name(id)],
          'photos': photoFiles[n.id] ?? const <String>[],
          'replies': [
            for (final r in allReplies.where((r) => r.noteId == n.id))
              {
                'id': r.id,
                if (r.parentId != null) 'reply_to': r.parentId,
                'author': name(r.authorId),
                'body': r.body,
                'at': r.createdAt.toIso8601String(),
                if (r.editedAt != null) 'edited_at': r.editedAt!.toIso8601String(),
                if (replyPhotoFiles[r.id] != null) 'photo': replyPhotoFiles[r.id],
              },
          ],
        },
    ];
    final exportedAt = (now ?? DateTime.now()).toUtc().toIso8601String();
    archive.addFile(
      ArchiveFile.string(
        'diary.json',
        const JsonEncoder.withIndent('  ').convert({'exported_at': exportedAt, 'posts': posts}),
      ),
    );
    archive.addFile(ArchiveFile.string('diary.html', _html(posts, exportedAt)));
    return ZipEncoder().encodeBytes(archive);
  }

  static String _html(List<Map<String, Object?>> posts, String exportedAt) {
    const esc = HtmlEscape();
    String para(String text) => esc.convert(text).replaceAll('\n', '<br>');
    final out = StringBuffer()
      ..writeln('<!doctype html><html><head><meta charset="utf-8">')
      ..writeln('<meta name="viewport" content="width=device-width, initial-scale=1">')
      ..writeln('<title>Our Diary</title><style>')
      ..writeln(
        'body{font-family:system-ui,sans-serif;max-width:640px;margin:24px auto;padding:0 16px;'
        'line-height:1.5;color:#2a2124;background:#fefaf3}',
      )
      ..writeln('article{border-bottom:1px solid #efe0df;padding:20px 0}h2{margin:4px 0;font-size:1.1em}')
      ..writeln('.meta{color:#7a666d;font-size:.9em}.photos img{max-width:100%;border-radius:10px;margin:8px 0}')
      ..writeln(
        '.reply{margin:8px 0 0 16px;padding-left:10px;border-left:2px solid #efe0df}'
        '.reply.answer{margin-left:40px}.reply img{max-width:240px;border-radius:10px;margin:6px 0}',
      )
      ..writeln('</style></head><body><h1>Our Diary</h1>')
      ..writeln('<p class="meta">Exported ${esc.convert(exportedAt)}</p>');
    for (final p in posts) {
      out.writeln(
        '<article><div class="meta">${esc.convert(p['author'] as String)} · ${p['day']}'
        '${p['status'] == 'draft' ? ' · Draft' : ''}</div>',
      );
      final title = p['title'] as String;
      if (title.trim().isNotEmpty) out.writeln('<h2>${esc.convert(title)}</h2>');
      out.writeln('<p>${para(p['body'] as String)}</p>');
      final photoList = p['photos'] as List<String>;
      if (photoList.isNotEmpty) {
        out.writeln('<div class="photos">${photoList.map((f) => '<img src="$f" alt="">').join()}</div>');
      }
      final likes = p['liked_by'] as List<String>;
      if (likes.isNotEmpty) out.writeln('<div class="meta">♥ ${esc.convert(likes.join(', '))}</div>');
      final all = p['replies'] as List<Map<String, Object?>>;
      void writeReply(Map<String, Object?> r) {
        final photo = r['photo'] as String?;
        out.writeln(
          '<div class="reply${r['reply_to'] != null ? ' answer' : ''}">'
          '<span class="meta">${esc.convert(r['author'] as String)}</span><br>'
          '${para(r['body'] as String)}${photo != null ? '<br><img src="$photo" alt="">' : ''}</div>',
        );
      }

      // Each reply, followed by its answers.
      for (final r in all.where((r) => r['reply_to'] == null)) {
        writeReply(r);
        all.where((a) => a['reply_to'] == r['id']).forEach(writeReply);
      }
      out.writeln('</article>');
    }
    out.writeln('</body></html>');
    return out.toString();
  }
}

/// Hands a finished export to the person: the share sheet on phones (save to
/// Files, Drive…), a download in the browser.
abstract interface class ExportSaver {
  Future<void> save(Uint8List bytes, String fileName);
}

class ShareExportSaver implements ExportSaver {
  const ShareExportSaver();

  @override
  Future<void> save(Uint8List bytes, String fileName) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'application/zip', name: fileName)],
        fileNameOverrides: [fileName],
        subject: 'Our Diary export',
      ),
    );
  }
}
