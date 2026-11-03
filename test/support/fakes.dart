import 'dart:async';
import 'dart:typed_data';

import 'package:secret_diary/core/app_dependencies.dart';
import 'package:secret_diary/core/auth/auth_session.dart';
import 'package:secret_diary/core/errors/app_failure.dart';
import 'package:secret_diary/core/device/device_services.dart';
import 'package:secret_diary/core/network/backend_client.dart';
import 'package:secret_diary/core/notifications/activity_check.dart';
import 'package:secret_diary/core/notifications/post_notifications.dart';
import 'package:secret_diary/core/storage/local_store.dart';
import 'package:secret_diary/core/sync/sync_service.dart';
import 'package:secret_diary/core/updates/releases.dart';
import 'package:secret_diary/features/access/data/access_repository.dart';
import 'package:secret_diary/features/export/diary_export.dart';
import 'package:secret_diary/features/access/models/welcome_content.dart';
import 'package:secret_diary/features/notes/data/notes_repository.dart';
import 'package:secret_diary/features/notes/models/note.dart';
import 'package:secret_diary/features/participants/data/participants_repository.dart';
import 'package:secret_diary/features/participants/models/participant.dart';
import 'package:secret_diary/features/photos/data/photos_repository.dart';
import 'package:secret_diary/features/photos/models/photo.dart';
import 'package:secret_diary/features/photos/services/photo_picker.dart';
import 'package:secret_diary/features/photos/services/photo_saver.dart';
import 'package:secret_diary/features/replies/data/replies_repository.dart';
import 'package:secret_diary/features/replies/models/reply.dart';

const meId = 'author-id';
const janinaId = 'janina-id';
const me = Participant(id: meId, key: 'author', displayName: 'Jarvey');
const janina = Participant(id: janinaId, key: 'janina', displayName: 'Janina');

final t0 = DateTime.utc(2026, 10, 28, 9);

Note note({
  String id = 'n1',
  String authorId = meId,
  String title = 'For Janina',
  String body = 'First paragraph.\n\nSecond paragraph,\nwith a line break.',
  NoteStatus status = NoteStatus.published,
  int version = 1,
  DateTime? at,
  DateTime? entryDate,
}) {
  final when = at ?? t0;
  return Note(
    id: id,
    authorId: authorId,
    title: title,
    body: body,
    status: status,
    entryDate: entryDate ?? DateTime(2026, 10, 28),
    version: version,
    createdAt: when,
    updatedAt: when,
    lastActivityAt: when,
    publishedAt: status == NoteStatus.published ? when : null,
  );
}

Reply reply({
  String id = 'r1',
  String noteId = 'n1',
  String authorId = janinaId,
  String body = 'Thank you.',
  DateTime? at,
}) => Reply(id: id, noteId: noteId, authorId: authorId, body: body, createdAt: at ?? t0.add(const Duration(hours: 1)));

/// Records calls and replies with a scripted response or error.
class FakeBackendClient implements BackendClient {
  Object? response;
  Object? error;
  final calls = <({String name, Map<String, dynamic>? body})>[];

  @override
  Future<Map<String, dynamic>> invokeFunction(
    String name, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    calls.add((name: name, body: body));
    if (error != null) throw error!;
    return response! as Map<String, dynamic>;
  }

  @override
  Future<Object?> rpc(String name, {Map<String, dynamic>? params}) async {
    calls.add((name: name, body: params));
    if (error != null) throw error!;
    return response;
  }
}

class FakeAuthSession implements AuthSession {
  FakeAuthSession([this._userId]);

  String? _userId;
  final refreshTokens = <String>[];
  final _signedOut = StreamController<void>.broadcast();

  @override
  String? get userId => _userId;

  set userId(String? id) => _userId = id;

  @override
  Future<void> establish({required String refreshToken}) async {
    refreshTokens.add(refreshToken);
  }

  @override
  Future<void> signOut() async {
    _userId = null;
    _signedOut.add(null);
  }

  /// Simulates the server ending the session (e.g. refresh token revoked).
  void expire() => signOut();

  @override
  Stream<void> get onSignedOut => _signedOut.stream;
}

/// Each passcode belongs to one person, like the real sign-in function.
class FakeAccessRepository implements AccessRepository {
  FakeAccessRepository(this.auth, {this.passcodes = const {'111111': meId, '135790': janinaId}});

  final FakeAuthSession auth;
  final Map<String, String> passcodes;
  AppFailure? nextFailure;
  int signInCalls = 0;

  @override
  Future<WelcomeContent> fetchWelcome() async => const WelcomeContent(
    recipientName: 'Janina',
    title: 'Hi, Janina.',
    message: "There's something I'd like you to read.",
  );

  @override
  Future<String> signIn(String passcode) async {
    signInCalls++;
    if (nextFailure != null) throw nextFailure!;
    final id = passcodes[passcode];
    if (id == null) throw const IncorrectPasscode(attemptsRemaining: 4);
    auth.userId = id;
    return id;
  }

  int verifyCalls = 0;

  @override
  Future<String> verifyPasscode(String passcode) async {
    verifyCalls++;
    if (nextFailure != null) throw nextFailure!;
    final id = passcodes[passcode];
    if (id == null) throw const IncorrectPasscode(attemptsRemaining: 4);
    return id;
  }
}

class FakeParticipantsRepository implements ParticipantsRepository {
  List<Participant> people = const [me, janina];
  AppFailure? nextFailure;

  @override
  Future<List<Participant>> fetchAll() async {
    if (nextFailure != null) throw nextFailure!;
    return people;
  }
}

/// In-memory notes that enforce the same visibility and version rules as RLS.
class FakeNotesRepository implements NotesRepository {
  FakeNotesRepository(this.auth, [List<Note> initial = const []]) {
    for (final n in initial) {
      store[n.id] = n;
    }
  }

  final FakeAuthSession auth;
  final store = <String, Note>{};
  AppFailure? nextFailure;
  int writes = 0;
  DateTime clock = t0.add(const Duration(days: 1));

  /// Supplies `replies(count)`; wired up by [FakeWorld].
  int Function(String noteId) countReplies = (_) => 0;

  /// Likes per entry, like the `note_likes` table.
  final likes = <String, Set<String>>{};
  final deleted = <String>[];

  /// Who has seen each entry, like `note_views`.
  final views = <String, Set<String>>{};

  /// Pins per person, like `note_pins`.
  final pins = <String, Set<String>>{};

  Note _withCount(Note n) => n.copyWith(
    replyCount: countReplies(n.id),
    likedBy: (likes[n.id] ?? const {}).toList(),
    seenBy: (views[n.id] ?? const {}).toList(),
    pinned: pins[auth.userId]?.contains(n.id) ?? false,
  );

  @override
  Future<void> markSeen(String noteId) async {
    if (nextFailure != null) throw nextFailure!;
    final n = store[noteId];
    if (n == null || n.status != NoteStatus.published || n.authorId == auth.userId) throw const NotAllowed();
    views.putIfAbsent(noteId, () => {}).add(auth.userId!);
  }

  @override
  Future<void> setPinned(String noteId, {required bool pinned}) async {
    if (nextFailure != null) throw nextFailure!;
    final n = store[noteId];
    if (n == null || !_visible(n)) throw const NotAllowed();
    final set = pins.putIfAbsent(auth.userId!, () => {});
    pinned ? set.add(noteId) : set.remove(noteId);
  }

  @override
  Future<void> setLiked(String noteId, {required bool liked}) async {
    if (nextFailure != null) throw nextFailure!;
    final n = store[noteId];
    if (n == null || n.status != NoteStatus.published) throw const NotAllowed();
    final set = likes.putIfAbsent(noteId, () => {});
    liked ? set.add(auth.userId!) : set.remove(auth.userId);
  }

  @override
  Future<void> deleteNote(String id) async {
    if (nextFailure != null) throw nextFailure!;
    final n = store[id];
    if (n == null || n.authorId != auth.userId) throw const NoteNotFound();
    store.remove(id);
    likes.remove(id);
    deleted.add(id);
  }

  bool _visible(Note n) => n.status == NoteStatus.published || n.authorId == auth.userId;

  DateTime _tick() => clock = clock.add(const Duration(minutes: 5));

  @override
  Future<List<Note>> fetchRecents() async {
    if (nextFailure != null) throw nextFailure!;
    return store.values.where(_visible).map(_withCount).toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
  }

  @override
  Future<Note> fetchNote(String id) async {
    if (nextFailure != null) throw nextFailure!;
    final n = store[id];
    if (n == null || !_visible(n)) throw const NoteNotFound();
    return _withCount(n);
  }

  @override
  Future<Note> createNote({
    required String id,
    required String title,
    required String body,
    required NoteStatus status,
    required DateTime entryDate,
  }) async {
    writes++;
    if (nextFailure != null) throw nextFailure!;
    if (store.containsKey(id)) return store[id]!;
    final now = _tick();
    return store[id] = Note(
      id: id,
      authorId: auth.userId!,
      title: title,
      body: body,
      status: status,
      entryDate: entryDate,
      version: 1,
      createdAt: now,
      updatedAt: now,
      lastActivityAt: now,
      publishedAt: status == NoteStatus.published ? now : null,
    );
  }

  @override
  Future<Note> updateNote({
    required String id,
    required int expectedVersion,
    required String title,
    required String body,
    required NoteStatus status,
    required DateTime entryDate,
  }) async {
    writes++;
    if (nextFailure != null) throw nextFailure!;
    final current = store[id];
    if (current == null || current.authorId != auth.userId) throw const NotAllowed();
    if (current.version != expectedVersion) throw EditConflict(current);
    final now = _tick();
    return store[id] = Note(
      id: id,
      authorId: current.authorId,
      title: title,
      body: body,
      status: status,
      entryDate: entryDate,
      version: current.version + 1,
      createdAt: current.createdAt,
      updatedAt: now,
      lastActivityAt: now,
      publishedAt: current.publishedAt ?? (status == NoteStatus.published ? now : null),
    );
  }

  /// Simulates an edit made on another device.
  void editElsewhere(String id, String body) {
    final c = store[id]!;
    store[id] = Note(
      id: id,
      authorId: c.authorId,
      title: c.title,
      body: body,
      status: c.status,
      entryDate: c.entryDate,
      version: c.version + 1,
      createdAt: c.createdAt,
      updatedAt: _tick(),
      lastActivityAt: clock,
      publishedAt: c.publishedAt,
    );
  }
}

class FakeRepliesRepository implements RepliesRepository {
  FakeRepliesRepository(this.auth, this.notes);

  final FakeAuthSession auth;
  final FakeNotesRepository notes;
  final store = <String, Reply>{};
  AppFailure? nextFailure;
  int sendCalls = 0;
  final sentIds = <String>[];

  /// When set, sends wait for this before completing (to test double taps).
  Completer<void>? gate;

  @override
  Future<List<Reply>> fetchReplies(String noteId) async {
    if (nextFailure != null) throw nextFailure!;
    return store.values.where((r) => r.noteId == noteId).map(_withLikes).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// Reply photos on the "server", by image path.
  final photoFiles = <String, Uint8List>{};

  @override
  Future<Reply> sendReply({
    required String id,
    required String noteId,
    required String body,
    String? parentId,
    PickedPhoto? photo,
  }) async {
    sendCalls++;
    sentIds.add(id);
    if (gate != null) await gate!.future;
    if (nextFailure != null) throw nextFailure!;
    final entry = notes.store[noteId];
    if (entry == null || entry.status != NoteStatus.published) throw const NotAllowed();
    if (parentId != null) {
      final parent = store[parentId];
      // One level only, on the same entry (as the database checks).
      if (parent == null || parent.noteId != noteId || parent.parentId != null) throw const InvalidContent();
    }
    if (body.trim().isEmpty && photo == null) throw const InvalidContent();
    if (photo != null) photoFiles['$id.jpg'] = photo.bytes;
    return store[id] ??= Reply(
      id: id,
      noteId: noteId,
      authorId: auth.userId!,
      body: body,
      createdAt: notes._tick(),
      parentId: parentId,
      imagePath: photo == null ? null : '$id.jpg',
    );
  }

  /// Likes per reply, like `reply_likes`.
  final likes = <String, Set<String>>{};
  int cleanUps = 0;

  @override
  Future<void> setLiked(String replyId, {required bool liked}) async {
    if (nextFailure != null) throw nextFailure!;
    if (!store.containsKey(replyId)) throw const NotAllowed();
    final set = likes.putIfAbsent(replyId, () => {});
    liked ? set.add(auth.userId!) : set.remove(auth.userId);
  }

  @override
  Future<void> cleanUpPhotos() async {
    cleanUps++;
    final inUse = {for (final r in store.values) r.imagePath};
    photoFiles.removeWhere((path, _) => !inUse.contains(path));
  }

  Reply _withLikes(Reply r) => r.copyWith(likedBy: (likes[r.id] ?? const {}).toList());

  @override
  Future<Uint8List> loadPhoto(String imagePath) async {
    final bytes = photoFiles[imagePath];
    if (bytes == null) throw const NoteNotFound();
    return bytes;
  }

  @override
  Future<List<Reply>> fetchRepliesFor(List<String> noteIds) async {
    if (nextFailure != null) throw nextFailure!;
    return store.values.where((r) => noteIds.contains(r.noteId)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<Reply> editReply({required String id, required String body}) async {
    if (nextFailure != null) throw nextFailure!;
    final current = store[id];
    if (current == null || current.authorId != auth.userId) throw const NotAllowed();
    return store[id] = current.copyWith(body: body, editedAt: notes._tick());
  }

  @override
  Future<void> deleteReply(Reply reply) async {
    if (nextFailure != null) throw nextFailure!;
    final current = store[reply.id];
    if (current != null && current.authorId != auth.userId) throw const NotAllowed();
    store.removeWhere((id, r) => id == reply.id || r.parentId == reply.id);
    await cleanUpPhotos();
  }

  /// Simulates the other person replying from their phone.
  Reply addFrom(String authorId, String noteId, String body, {String? parentId, bool withPhoto = false}) {
    final id = 'remote-${store.length}';
    if (withPhoto) photoFiles['$id.jpg'] = pngBytes;
    final r = Reply(
      id: id,
      noteId: noteId,
      authorId: authorId,
      body: body,
      createdAt: notes._tick(),
      parentId: parentId,
      imagePath: withPhoto ? '$id.jpg' : null,
    );
    return store[r.id] = r;
  }
}

/// A valid 1x1 PNG, so Image.memory can decode it in widget tests.
final pngBytes = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0xF0,
  0x1F,
  0x00,
  0x05,
  0x00,
  0x01,
  0xFF,
  0x89,
  0x99,
  0x3D,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

PickedPhoto picked() => PickedPhoto(pngBytes, 'png');

/// In-memory photos that follow the same rules as the database: visible with
/// their entry, only the entry's author can change them, at most three.
class FakePhotosRepository implements PhotosRepository {
  FakePhotosRepository(this.auth, this.notes);

  final FakeAuthSession auth;
  final FakeNotesRepository notes;
  final store = <String, NotePhoto>{};
  final files = <String, Uint8List>{};
  AppFailure? nextFailure;

  /// Fail only the n-th add from now (1 = the next one).
  int? failAddNumber;
  int addCalls = 0;
  final addedIds = <String>[];

  @override
  Future<List<NotePhoto>> fetchPhotos(String noteId) async {
    if (nextFailure != null) throw nextFailure!;
    await notes.fetchNote(noteId); // same visibility as the entry
    return store.values.where((p) => p.noteId == noteId).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<Map<String, List<NotePhoto>>> fetchPhotosFor(List<String> noteIds) async {
    if (nextFailure != null) throw nextFailure!;
    final byNote = <String, List<NotePhoto>>{};
    for (final p in store.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt))) {
      final note = notes.store[p.noteId];
      final visible = note != null && (note.status == NoteStatus.published || note.authorId == auth.userId);
      if (noteIds.contains(p.noteId) && visible) (byNote[p.noteId] ??= []).add(p);
    }
    return byNote;
  }

  @override
  Future<NotePhoto> addPhoto({required String id, required String noteId, required PickedPhoto photo}) async {
    addCalls++;
    addedIds.add(id);
    final failIn = failAddNumber;
    if (failIn != null) {
      failAddNumber = failIn == 1 ? null : failIn - 1;
      if (failIn == 1) throw const NoConnection();
    }
    if (nextFailure != null) throw nextFailure!;
    final existing = store[id];
    if (existing != null) return existing;
    final note = notes.store[noteId];
    if (note == null || note.authorId != auth.userId) throw const NotAllowed();
    if (store.values.where((p) => p.noteId == noteId).length >= 3) {
      throw const InvalidContent();
    }
    final path = '$noteId/$id.${photo.extension}';
    files[path] = photo.bytes;
    return store[id] = NotePhoto(
      id: id,
      noteId: noteId,
      authorId: auth.userId!,
      storagePath: path,
      createdAt: notes._tick(),
    );
  }

  @override
  Future<void> removePhoto(NotePhoto photo) async {
    if (nextFailure != null) throw nextFailure!;
    final note = notes.store[photo.noteId];
    if (note == null || note.authorId != auth.userId) throw const NotAllowed();
    store.remove(photo.id);
    files.remove(photo.storagePath);
  }

  final removedFiles = <String>[];

  @override
  Future<void> removeFiles(List<String> storagePaths) async {
    removedFiles.addAll(storagePaths);
    storagePaths.forEach(files.remove);
    store.removeWhere((_, p) => storagePaths.contains(p.storagePath));
  }

  @override
  Future<Uint8List> loadPhoto(String storagePath) async {
    final bytes = files[storagePath];
    if (bytes == null) throw const NoteNotFound();
    return bytes;
  }

  /// Paths the feed asked for as previews.
  final previewsLoaded = <String>[];

  @override
  Future<Uint8List> loadPreview(String storagePath) {
    previewsLoaded.add(storagePath);
    return loadPhoto(storagePath);
  }

  /// A photo already saved on the server.
  NotePhoto seed(String id, String noteId, {String authorId = meId}) {
    final path = '$noteId/$id.png';
    files[path] = pngBytes;
    return store[id] = NotePhoto(
      id: id,
      noteId: noteId,
      authorId: authorId,
      storagePath: path,
      createdAt: notes._tick(),
    );
  }
}

/// Returns scripted picks; records what limit the app asked for.
class FakePhotoPicker implements PhotoPicker {
  List<PickedPhoto> next = const [];
  AppFailure? nextFailure;
  final requests = <({PhotoSource source, int limit})>[];

  @override
  Future<List<PickedPhoto>> pick(PhotoSource source, {required int limit}) async {
    requests.add((source: source, limit: limit));
    if (nextFailure != null) throw nextFailure!;
    return next.take(limit).toList();
  }
}

class FakeSyncService implements SyncService {
  final _events = StreamController<SyncEvent>.broadcast();
  bool started = false;

  @override
  Stream<SyncEvent> get events => _events.stream;

  @override
  void start() => started = true;

  @override
  Future<void> stop() async => started = false;

  void emit(SyncEvent event) => _events.add(event);
}

/// Everything wired together, as both people share one in-memory "server".
class FakeWorld {
  FakeWorld({String? signedInAs, List<Note>? notes}) : auth = FakeAuthSession(signedInAs) {
    this.notes = FakeNotesRepository(auth, notes ?? [note()]);
    replies = FakeRepliesRepository(auth, this.notes);
    photos = FakePhotosRepository(auth, this.notes);
    this.notes.countReplies = (id) => replies.store.values.where((r) => r.noteId == id).length;
    access = FakeAccessRepository(auth);
  }

  final FakeAuthSession auth;
  late final FakeNotesRepository notes;
  late final FakeRepliesRepository replies;
  late final FakePhotosRepository photos;
  final picker = FakePhotoPicker();
  late final FakeAccessRepository access;
  final participants = FakeParticipantsRepository();
  final sync = FakeSyncService();
  final notifications = FakePostNotifications();
  final activity = FakeActivityChecker();
  final store = FakeLocalStore();
  final screenLock = FakeScreenLock();

  /// Replaces [screenLock], e.g. with the web version's passcode lock.
  ScreenLock? screenLockOverride;
  final background = FakeBackgroundRunning();
  final releases = FakeReleasesRepository();
  int buildNumber = 1;
  final exportSaver = FakeExportSaver();
  final photoSaver = FakePhotoSaver();

  AppDependencies get dependencies => AppDependencies(
    accessRepository: access,
    authSession: auth,
    participantsRepository: participants,
    notesRepository: notes,
    repliesRepository: replies,
    photosRepository: photos,
    photoPicker: picker,
    syncService: sync,
    notifications: notifications,
    activity: activity,
    localStore: store,
    screenLock: screenLockOverride ?? screenLock,
    backgroundRunning: background,
    releases: releases,
    buildNumber: buildNumber,
    exportSaver: exportSaver,
    photoSaver: photoSaver,
  );
}

class FakePostNotifications implements PostNotifications {
  final tapsController = StreamController<String>.broadcast();
  final announced = <NewActivity>[];
  DateTime? seen;
  String? launchNoteId;
  bool permissionAsked = false;

  @override
  Stream<String> get taps => tapsController.stream;

  @override
  Future<String?> takeLaunchNoteId() async {
    final id = launchNoteId;
    launchNoteId = null;
    return id;
  }

  @override
  Future<void> requestPermission() async => permissionAsked = true;

  @override
  Future<DateTime?> lastSeen() async => seen;

  @override
  Future<void> markSeen(DateTime postedAt) async {
    if (seen == null || postedAt.isAfter(seen!)) seen = postedAt;
  }

  @override
  Future<void> announce(List<NewActivity> posts) async => announced.addAll(posts);
}

class FakeActivityChecker implements ActivityChecker {
  /// One entry per check: true when it was asked to announce.
  final calls = <bool>[];

  @override
  Future<void> catchUp({required bool announce}) async => calls.add(announce);
}

class FakeLocalStore implements LocalStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

class FakeScreenLock implements ScreenLock {
  /// Off by default so most tests open straight into the app.
  bool available = false;
  bool succeed = true;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> unlock() async {
    prompts++;
    return succeed;
  }

  @override
  bool get usesPasscode => false;

  @override
  Future<AppFailure?> unlockWithPasscode(String passcode) async => const NotAllowed();
}

class FakeBackgroundRunning implements BackgroundRunning {
  bool unrestricted = true;
  int asked = 0;

  @override
  Future<bool> isUnrestricted() async => unrestricted;

  @override
  Future<void> askUnrestricted() async => asked++;
}

class FakeReleasesRepository implements ReleasesRepository {
  AppRelease? release;

  @override
  Future<AppRelease?> latest() async => release;
}

class FakePhotoSaver implements PhotoSaver {
  final saved = <Uint8List>[];
  AppFailure? nextFailure;

  @override
  Future<void> save(Uint8List bytes) async {
    if (nextFailure != null) throw nextFailure!;
    saved.add(bytes);
  }
}

class FakeExportSaver implements ExportSaver {
  Uint8List? bytes;
  String? fileName;

  @override
  Future<void> save(Uint8List bytes, String fileName) async {
    this.bytes = bytes;
    this.fileName = fileName;
  }
}
