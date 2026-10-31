import 'package:flutter_test/flutter_test.dart';
import 'package:secret_diary/core/errors/app_failure.dart';
import 'package:secret_diary/features/notes/models/note.dart';
import 'package:secret_diary/features/notes/services/note_editor_controller.dart';
import 'package:secret_diary/features/notes/services/notes_controller.dart';
import 'package:secret_diary/features/photos/models/photo.dart';

import '../../support/fakes.dart';

void main() {
  group('NotesController', () {
    late FakeWorld world;

    NotesController controller() => NotesController(
          notes: world.notes,
          participants: world.participants,
          photos: world.photos,
          currentUserId: world.auth.userId,
        );

    setUp(() => world = FakeWorld(signedInAs: janinaId, notes: [
          note(id: 'old', at: t0),
          note(id: 'new', authorId: janinaId, title: 'From me', at: t0.add(const Duration(hours: 2))),
          note(id: 'his-draft', authorId: meId, status: NoteStatus.draft, at: t0.add(const Duration(hours: 3))),
          note(id: 'my-draft', authorId: janinaId, status: NoteStatus.draft, at: t0.add(const Duration(hours: 4))),
        ]));

    test('the feed holds shared entries from both, newest post first', () async {
      final c = controller();
      await c.load();

      expect(c.feed.map((n) => n.id), ['new', 'old']);
      expect(c.me?.displayName, 'Janina');
      expect(c.other?.displayName, 'Jarvey');
      expect(c.nameOf(meId), 'Jarvey');
    });

    test('profile lists: my shared entries and only my drafts', () async {
      final c = controller();
      await c.load();
      expect(c.myEntries.map((n) => n.id), ['new']);
      expect(c.myDrafts.map((n) => n.id), ['my-draft']);
    });

    test('photos and reply counts arrive with the feed', () async {
      world.photos.seed('p1', 'old');
      world.photos.seed('secret', 'his-draft');
      world.replies.addFrom(meId, 'old', 'hi');
      final c = controller();
      await c.load();

      expect(c.photosOf('old').map((p) => p.id), ['p1']);
      expect(c.photosOf('his-draft'), isEmpty);
      expect(c.feed.firstWhere((n) => n.id == 'old').replyCount, 1);
    });

    test('a signed-in account that is not a participant is refused', () async {
      world.auth.userId = 'stranger';
      final c = controller();
      await c.load();
      expect(c.failure, isA<NotAllowed>());
    });

    test('a failed refresh keeps the feed and reports the failure', () async {
      final c = controller();
      await c.load();
      world.notes.nextFailure = const NoConnection();

      expect(await c.refresh(), isA<NoConnection>());
      expect(c.feed, hasLength(2));
      expect(c.failure, isNull);
    });

    test('applySaved shows a just-shared entry at the top', () async {
      final c = controller();
      await c.load();
      c.applySaved(note(id: 'fresh', authorId: janinaId, at: t0.add(const Duration(days: 2))));
      expect(c.feed.first.id, 'fresh');
    });
  });

  group('NoteEditorController', () {
    late FakeWorld world;
    final day = DateTime(2026, 10, 30);
    var ids = 0;

    NoteEditorController editor({Note? existing, List<NotePhoto> photos = const []}) =>
        NoteEditorController(
          repository: world.notes,
          photos: world.photos,
          existing: existing,
          existingPhotos: photos,
          idGenerator: () => 'id-${ids++}',
        );

    Future<Note?> save(NoteEditorController e, String body, NoteStatus status, {String title = 'T'}) =>
        e.save(title: title, body: body, status: status, entryDate: day);

    setUp(() {
      ids = 0;
      world = FakeWorld(signedInAs: janinaId, notes: []);
    });

    test('saves a new draft, then shares the same entry', () async {
      final e = editor();

      final draft = await save(e, 'Not finished', NoteStatus.draft, title: 'Hi');
      expect(draft?.id, 'id-0');
      expect(draft?.isDraft, isTrue);
      expect(draft?.authorId, janinaId);
      expect(draft?.entryDate, day);

      final sent = await save(e, 'Finished.', NoteStatus.published, title: 'Hi');
      expect(sent?.id, 'id-0');
      expect(sent?.status, NoteStatus.published);
      expect(world.notes.store, hasLength(1));
    });

    test('sharing an empty entry is refused locally', () async {
      final e = editor();
      expect(await save(e, '  ', NoteStatus.published), isNull);
      expect(e.failure, isA<InvalidContent>());
      expect(world.notes.writes, 0);
    });

    test('a failed save keeps the editor usable and reports why', () async {
      final e = editor();
      world.notes.nextFailure = const NoConnection();
      expect(await save(e, 'b', NoteStatus.draft), isNull);
      expect(e.failure, isA<NoConnection>());
      expect(e.isSaving, isFalse);

      world.notes.nextFailure = null;
      expect(await save(e, 'b', NoteStatus.draft), isNotNull);
    });

    test('an edit made elsewhere is detected, not silently overwritten', () async {
      final existing = note(id: 'n', authorId: janinaId);
      world.notes.store['n'] = existing;
      final e = editor(existing: existing);
      world.notes.editElsewhere('n', 'Edited on the other phone');

      expect(await save(e, 'My edit', NoteStatus.published), isNull);
      expect(e.failure, isA<EditConflict>());
      expect(e.conflict?.body, 'Edited on the other phone');
      expect(world.notes.store['n']!.body, 'Edited on the other phone');

      e.keepMine();
      final saved = await save(e, 'My edit', NoteStatus.published);
      expect(saved?.body, 'My edit');
    });

    test('takeLatest hands back the newer version', () async {
      final existing = note(id: 'n', authorId: janinaId);
      world.notes.store['n'] = existing;
      final e = editor(existing: existing);
      world.notes.editElsewhere('n', 'Newer');
      await save(e, 'Mine', NoteStatus.published);

      expect(e.takeLatest()?.body, 'Newer');
      expect(e.conflict, isNull);
    });

    group('photos', () {
      test('allows at most three', () {
        final e = editor();
        e.addPhotos([picked(), picked()]);
        e.addPhotos([picked(), picked()]);
        expect(e.photos, hasLength(3));
        expect(e.photosLeft, 0);
      });

      test('a new shared entry is uploaded with its photos', () async {
        final e = editor();
        e.addPhotos([picked(), picked()]);
        final saved = await save(e, 'With photos', NoteStatus.published);

        expect(saved?.status, NoteStatus.published);
        final photos = world.photos.store.values.toList();
        expect(photos, hasLength(2));
        expect(photos.every((p) => p.noteId == saved!.id && p.authorId == janinaId), isTrue);
        expect(e.photosChanged, isFalse);
      });

      test('a new entry stays a draft until its photos are up', () async {
        final e = editor();
        e.addPhotos([picked(), picked()]);
        world.photos.failAddNumber = 2;

        expect(await save(e, 'Text', NoteStatus.published), isNull);
        expect(e.failure, isA<PhotosNotSaved>());
        // The other person can't see a half-finished entry.
        expect(world.notes.store.values.single.status, NoteStatus.draft);
        expect(e.photos, hasLength(2));
        expect(e.photosChanged, isTrue);

        final saved = await save(e, 'Text', NoteStatus.published);
        expect(saved?.status, NoteStatus.published);
        expect(world.photos.store, hasLength(2));
        expect(world.notes.store, hasLength(1));
      });

      test('a retried upload reuses the photo id, so it cannot duplicate', () async {
        final e = editor();
        e.addPhotos([picked()]);
        world.photos.failAddNumber = 1;
        await save(e, 'Text', NoteStatus.draft);
        await save(e, 'Text', NoteStatus.draft);

        expect(world.photos.addedIds, hasLength(2));
        expect(world.photos.addedIds.toSet(), hasLength(1));
        expect(world.photos.store, hasLength(1));
      });

      test('removing and adding on a full entry swaps the photo', () async {
        world.notes.store['n'] = note(id: 'n', authorId: janinaId);
        final existing = [
          world.photos.seed('a', 'n', authorId: janinaId),
          world.photos.seed('b', 'n', authorId: janinaId),
          world.photos.seed('c', 'n', authorId: janinaId),
        ];
        final e = editor(existing: world.notes.store['n'], photos: existing);
        expect(e.photosLeft, 0);

        e.removePhoto('b');
        e.addPhotos([picked()]);
        expect(await save(e, 'Body', NoteStatus.published), isNotNull);
        expect(world.photos.store.keys, containsAll(['a', 'c']));
        expect(world.photos.store.containsKey('b'), isFalse);
        expect(world.photos.store, hasLength(3));
      });

      test('removing a picked photo that was never uploaded sends nothing', () async {
        final e = editor();
        e.addPhotos([picked()]);
        e.removePhoto(e.photos.single.id);
        await save(e, 'Body', NoteStatus.draft);
        expect(world.photos.addCalls, 0);
      });
    });
  });
}
