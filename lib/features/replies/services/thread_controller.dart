import 'package:flutter/foundation.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/ids.dart';
import '../../notes/data/notes_repository.dart';
import '../../notes/models/note.dart';
import '../../photos/data/photos_repository.dart';
import '../../photos/models/photo.dart';
import '../data/replies_repository.dart';
import '../models/reply.dart';

/// One open entry, its photos, and its conversation.
class ThreadController extends ChangeNotifier {
  ThreadController({
    required this.noteId,
    required NotesRepository notes,
    required RepliesRepository replies,
    required PhotosRepository photos,
    IdGenerator idGenerator = newId,
  }) : _notes = notes,
       _replies = replies,
       _photos = photos,
       _newId = idGenerator;

  final String noteId;
  final NotesRepository _notes;
  final RepliesRepository _replies;
  final PhotosRepository _photos;
  final IdGenerator _newId;

  Note? _note;
  List<Reply> _thread = const [];
  List<NotePhoto> _photoList = const [];
  bool _loading = false;
  AppFailure? _failure;
  bool _sending = false;
  AppFailure? _sendFailure;
  bool _disposed = false;

  // A send that failed keeps its id, so retrying the same text can't duplicate.
  String? _pendingId;
  String? _pendingText;

  Note? get note => _note;
  List<Reply> get replies => _thread;
  List<NotePhoto> get photos => _photoList;
  bool get isLoading => _loading;

  /// Set when the note could not be shown at all.
  AppFailure? get failure => _failure;
  bool get isSending => _sending;
  AppFailure? get sendFailure => _sendFailure;

  /// Loads the latest note and replies. With [silent], a failed refresh keeps
  /// what is already on screen and returns the failure instead.
  Future<AppFailure?> load({bool silent = false}) async {
    if (_loading) return null;
    _loading = true;
    if (!silent) _failure = null;
    _notify();
    try {
      final results = await Future.wait([
        _notes.fetchNote(noteId),
        _replies.fetchReplies(noteId),
        _photos.fetchPhotos(noteId),
      ]);
      _note = results[0] as Note;
      _thread = results[1] as List<Reply>;
      _photoList = results[2] as List<NotePhoto>;
      _failure = null;
      return null;
    } on AppFailure catch (f) {
      final transient = f is NoConnection || f is ServiceUnavailable;
      if (silent && _note != null && transient) return f;
      _note = null;
      _thread = const [];
      _photoList = const [];
      _failure = f;
      return f;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Sends [text] as a reply. Returns the saved reply, or null if it failed
  /// (with [sendFailure] set). Never reports success for an unsaved reply.
  Future<Reply?> send(String text) async {
    final body = text.trim();
    if (body.isEmpty || _sending) return null;

    if (_pendingText != body) {
      _pendingId = _newId();
      _pendingText = body;
    }
    _sending = true;
    _sendFailure = null;
    _notify();

    try {
      final reply = await _replies.sendReply(id: _pendingId!, noteId: noteId, body: body);
      if (!_thread.any((r) => r.id == reply.id)) {
        _thread = [..._thread, reply]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      }
      _pendingId = null;
      _pendingText = null;
      return reply;
    } on AppFailure catch (f) {
      _sendFailure = f;
      return null;
    } finally {
      _sending = false;
      _notify();
    }
  }

  /// Likes or unlikes the open entry right away; reverts if the server says no.
  Future<AppFailure?> toggleLike(String? meId) async {
    final current = _note;
    if (current == null || meId == null || current.isDraft) return null;
    final like = !current.isLikedBy(meId);
    _note = current.copyWith(
      likedBy: like ? [...current.likedBy, meId] : current.likedBy.where((id) => id != meId).toList(),
    );
    _notify();
    try {
      await _notes.setLiked(noteId, liked: like);
      return null;
    } on AppFailure catch (f) {
      _note = current;
      _notify();
      return f;
    }
  }

  /// Changes the text of your own reply. Returns the failure, if any.
  Future<AppFailure?> editReply(Reply reply, String text) async {
    final body = text.trim();
    if (body.isEmpty || body == reply.body) return null;
    try {
      final saved = await _replies.editReply(id: reply.id, body: body);
      _thread = [for (final r in _thread) r.id == saved.id ? saved : r];
      _notify();
      return null;
    } on AppFailure catch (f) {
      return f;
    }
  }

  /// Deletes your own reply. Returns the failure, if any.
  Future<AppFailure?> deleteReply(Reply reply) async {
    try {
      await _replies.deleteReply(reply.id);
      _thread = _thread.where((r) => r.id != reply.id).toList();
      _notify();
      return null;
    } on AppFailure catch (f) {
      return f;
    }
  }

  void clearSendFailure() {
    if (_sendFailure == null) return;
    _sendFailure = null;
    _notify();
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
