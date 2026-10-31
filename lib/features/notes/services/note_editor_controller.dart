import 'package:flutter/foundation.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/ids.dart';
import '../../photos/data/photos_repository.dart';
import '../../photos/models/photo.dart';
import '../data/notes_repository.dart';
import '../models/note.dart';

/// Saving a new or existing diary entry and its photos. The text itself lives
/// in the screen's text controllers, so it survives any failed save; picked
/// photos stay here until they are uploaded.
class NoteEditorController extends ChangeNotifier {
  NoteEditorController({
    required NotesRepository repository,
    required PhotosRepository photos,
    Note? existing,
    List<NotePhoto> existingPhotos = const [],
    IdGenerator idGenerator = newId,
  }) : _repository = repository,
       _photos = photos,
       _base = existing,
       _savedPhotos = List.of(existingPhotos),
       _newId = idGenerator,
       noteId = existing?.id ?? idGenerator();

  static const maxPhotos = 3;

  final NotesRepository _repository;
  final PhotosRepository _photos;
  final IdGenerator _newId;

  /// The id is fixed up front so retrying a create can't duplicate the note.
  final String noteId;

  /// The version being edited (null until the note exists on the server).
  Note? _base;
  final List<NotePhoto> _savedPhotos;
  final _removedPhotos = <NotePhoto>[];
  final _pickedPhotos = <EditorPhoto>[];
  bool _saving = false;
  AppFailure? _failure;
  Note? _conflict;
  bool _disposed = false;

  Note? get base => _base;
  bool get isNew => _base == null;
  NoteStatus get status => _base?.status ?? NoteStatus.draft;
  bool get isSaving => _saving;
  AppFailure? get failure => _failure;

  /// Set when the server has a newer version than the one being edited.
  Note? get conflict => _conflict;

  /// What the entry will have once saved: kept photos, then newly picked ones.
  List<EditorPhoto> get photos => [
    for (final p in _savedPhotos)
      if (!_removedPhotos.contains(p)) EditorPhoto.saved(p),
    ..._pickedPhotos,
  ];

  int get photosLeft => maxPhotos - photos.length;

  /// True while there are photo changes that haven't reached the server.
  bool get photosChanged => _pickedPhotos.isNotEmpty || _removedPhotos.isNotEmpty;

  /// Adds picked photos, ignoring any beyond the limit of three.
  void addPhotos(List<PickedPhoto> picked) {
    final room = photosLeft;
    if (room <= 0 || picked.isEmpty) return;
    _pickedPhotos.addAll(picked.take(room).map((p) => EditorPhoto.picked(_newId(), p)));
    _notify();
  }

  void removePhoto(String id) {
    final before = photos.length;
    _pickedPhotos.removeWhere((p) => p.id == id);
    final saved = _savedPhotos.where((p) => p.id == id).firstOrNull;
    if (saved != null && !_removedPhotos.contains(saved)) _removedPhotos.add(saved);
    if (photos.length != before) _notify();
  }

  /// Saves with the given [status]. Returns the saved note, or null on failure.
  Future<Note?> save({
    required String title,
    required String body,
    required NoteStatus status,
    required DateTime entryDate,
  }) async {
    if (_saving) return null;
    if (status == NoteStatus.published && body.trim().isEmpty) {
      _failure = const InvalidContent('Write something before sharing this post.');
      _notify();
      return null;
    }

    _saving = true;
    _failure = null;
    _notify();
    try {
      // An entry being shared for the first time stays a draft until its
      // photos are up, so the other person never sees it half-finished.
      final holdBack = status == NoteStatus.published && (_base == null || _base!.isDraft) && photosChanged;
      var saved = await _write(title, body, holdBack ? NoteStatus.draft : status, entryDate);

      try {
        await _syncPhotos();
      } on AppFailure catch (f) {
        _failure = PhotosNotSaved(f);
        return null;
      }

      if (saved.status != status) saved = await _write(title, body, status, entryDate);
      return saved;
    } on EditConflict catch (c) {
      _conflict = c.latest as Note;
      _failure = c;
      return null;
    } on AppFailure catch (f) {
      _failure = f;
      return null;
    } finally {
      _saving = false;
      _notify();
    }
  }

  Future<Note> _write(String title, String body, NoteStatus status, DateTime entryDate) async {
    final base = _base;
    final saved = base == null
        ? await _repository.createNote(
            id: noteId,
            title: title.trim(),
            body: body,
            status: status,
            entryDate: entryDate,
          )
        : await _repository.updateNote(
            id: noteId,
            expectedVersion: base.version,
            title: title.trim(),
            body: body,
            status: status,
            entryDate: entryDate,
          );
    _base = saved;
    _conflict = null;
    return saved;
  }

  /// Removals first, so swapping a photo never trips the limit of three.
  Future<void> _syncPhotos() async {
    for (final photo in List.of(_removedPhotos)) {
      await _photos.removePhoto(photo);
      _removedPhotos.remove(photo);
      _savedPhotos.remove(photo);
      _notify();
    }
    for (final picked in List.of(_pickedPhotos)) {
      final saved = await _photos.addPhoto(id: picked.id, noteId: noteId, photo: picked.picked!);
      _pickedPhotos.remove(picked);
      _savedPhotos.add(saved);
      _notify();
    }
  }

  /// Keep my text: the next save overwrites the newer version on purpose.
  void keepMine() {
    final latest = _conflict;
    if (latest == null) return;
    _base = latest;
    _conflict = null;
    _failure = null;
    _notify();
  }

  /// Discard my text: returns the newer version to load into the editor.
  Note? takeLatest() {
    final latest = _conflict;
    if (latest == null) return null;
    _base = latest;
    _conflict = null;
    _failure = null;
    _notify();
    return latest;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
