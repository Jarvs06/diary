import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/storage/local_store.dart';
import '../../participants/data/participants_repository.dart';
import '../../participants/models/participant.dart';
import '../../photos/data/photos_repository.dart';
import '../../photos/models/photo.dart';
import '../data/notes_repository.dart';
import '../models/note.dart';

/// The feed, your own entries and drafts, their photos, and the two people.
class NotesController extends ChangeNotifier {
  NotesController({
    required NotesRepository notes,
    required ParticipantsRepository participants,
    required PhotosRepository photos,
    required String? currentUserId,
    LocalStore? store,
  }) : _notes = notes,
       _participants = participants,
       _photos = photos,
       _meId = currentUserId,
       _store = store;

  final NotesRepository _notes;
  final ParticipantsRepository _participants;
  final PhotosRepository _photos;
  final String? _meId;

  /// Keeps a copy of the latest feed for reading without a connection.
  final LocalStore? _store;
  static const _cacheKey = 'feed_cache';
  bool _offline = false;

  Map<String, Participant> _people = const {};
  List<Note> _all = const [];
  Map<String, List<NotePhoto>> _photoMap = const {};
  bool _loading = true;
  bool _refreshing = false;
  AppFailure? _failure;
  bool _disposed = false;

  bool get isLoading => _loading;
  bool get isRefreshing => _refreshing;

  /// Showing the saved copy because the server couldn't be reached.
  bool get isOffline => _offline;

  /// Set when nothing could be shown at all.
  AppFailure? get failure => _failure;

  /// Shared entries from both people, newest first by the entry's date (the
  /// day it's about, which is the posting day unless Jarvey picked another);
  /// entries on the same day are newest post first.
  List<Note> get feed => _all.where((n) => !n.isDraft).toList()
    ..sort((a, b) {
      final byDay = b.entryDate.compareTo(a.entryDate);
      return byDay != 0 ? byDay : b.postedAt.compareTo(a.postedAt);
    });

  /// Your shared entries, newest first.
  List<Note> get myEntries => feed.where((n) => isMine(n.authorId)).toList();

  /// Your drafts, most recently edited first. (The server never sends the
  /// other person's drafts.)
  List<Note> get myDrafts =>
      _all.where((n) => n.isDraft && isMine(n.authorId)).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<NotePhoto> photosOf(String noteId) => _photoMap[noteId] ?? const [];

  /// Everything you can see (shared posts and your drafts), for the export.
  List<Note> get everything => [...feed, ...myDrafts];
  Map<String, Participant> get people => _people;

  Participant? get me => _people[_meId];
  Participant? get other => _people.values.where((p) => p.id != _meId).firstOrNull;
  bool isMine(String authorId) => authorId == _meId;
  String? get meId => _meId;
  String nameOf(String participantId) => _people[participantId]?.displayName ?? 'Someone';

  Future<void> load() async {
    _loading = true;
    _failure = null;
    _notify();
    try {
      final results = await Future.wait([_participants.fetchAll(), _notes.fetchRecents()]);
      final people = results[0] as List<Participant>;
      if (!people.any((p) => p.id == _meId)) throw const NotAllowed();
      _people = {for (final p in people) p.id: p};
      _all = results[1] as List<Note>;
      _offline = false;
      await _loadPhotos();
      unawaited(_saveCopy());
    } on AppFailure catch (f) {
      if (!(f is NoConnection || f is ServiceUnavailable) || !await _loadCopy()) _failure = f;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Re-fetches everything, keeping what's shown if the refresh fails.
  /// Returns the failure, if any, so the caller can show a brief notice.
  Future<AppFailure?> refresh() async {
    if (_loading) return null;
    if (_failure != null) {
      await load();
      return _failure;
    }
    _refreshing = true;
    _notify();
    try {
      _all = await _notes.fetchRecents();
      if (_offline) _people = {for (final p in await _participants.fetchAll()) p.id: p};
      _offline = false;
      await _loadPhotos();
      unawaited(_saveCopy());
      return null;
    } on AppFailure catch (f) {
      return f;
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  /// Puts a just-saved entry in place without waiting for a refresh.
  void applySaved(Note note) {
    final old = _all.where((n) => n.id == note.id).firstOrNull;
    final merged = old == null ? note : note.copyWith(replyCount: old.replyCount, likedBy: old.likedBy);
    _all = [merged, ..._all.where((n) => n.id != note.id)];
    _notify();
  }

  /// Likes or unlikes right away; puts it back if the server says no.
  Future<AppFailure?> toggleLike(Note note) async {
    final current = _all.where((n) => n.id == note.id).firstOrNull ?? note;
    final like = !current.isLikedBy(_meId);
    _replace(
      current.copyWith(
        likedBy: like ? [...current.likedBy, _meId!] : current.likedBy.where((id) => id != _meId).toList(),
      ),
    );
    try {
      await _notes.setLiked(note.id, liked: like);
      return null;
    } on AppFailure catch (f) {
      _replace(current);
      return f;
    }
  }

  /// Deletes your own entry, then its photo files. Returns the failure, if any.
  Future<AppFailure?> delete(Note note) async {
    final photos = photosOf(note.id).map((p) => p.storagePath).toList();
    try {
      await _notes.deleteNote(note.id);
    } on NoteNotFound {
      // Already gone (e.g. deleted on the other phone): treat as done.
    } on AppFailure catch (f) {
      return f;
    }
    _all = _all.where((n) => n.id != note.id).toList();
    _photoMap = {..._photoMap}..remove(note.id);
    _notify();
    await _photos.removeFiles(photos);
    return null;
  }

  /// Saves the newest 100 shared entries and your drafts.
  Future<void> _saveCopy() async {
    final store = _store;
    if (store == null) return;
    final notes = [...feed.take(100), ...myDrafts];
    await store.write(
      _cacheKey,
      jsonEncode({
        'me': _meId,
        'people': [for (final p in _people.values) p.toJson()],
        'notes': [for (final n in notes) n.toJson()],
      }),
    );
  }

  /// Shows the saved copy, if there is one for this account.
  Future<bool> _loadCopy() async {
    final raw = await _store?.read(_cacheKey);
    if (raw == null) return false;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['me'] != _meId) return false;
      _people = {
        for (final p in (json['people'] as List).cast<Map<String, dynamic>>())
          p['id'] as String: Participant.fromJson(p),
      };
      _all = [for (final n in (json['notes'] as List).cast<Map<String, dynamic>>()) Note.fromJson(n)];
      _photoMap = const {};
      _offline = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _replace(Note note) {
    _all = [for (final n in _all) n.id == note.id ? note : n];
    _notify();
  }

  Future<void> _loadPhotos() async {
    _photoMap = await _photos.fetchPhotosFor(_all.map((n) => n.id).toList());
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
