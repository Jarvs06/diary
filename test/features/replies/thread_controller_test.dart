import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secret_diary/core/errors/app_failure.dart';
import 'package:secret_diary/features/notes/models/note.dart';
import 'package:secret_diary/features/replies/services/thread_controller.dart';

import '../../support/fakes.dart';

void main() {
  late FakeWorld world;
  var ids = 0;

  ThreadController thread([String noteId = 'n1']) => ThreadController(
        noteId: noteId,
        notes: world.notes,
        replies: world.replies,
        photos: world.photos,
        idGenerator: () => 'reply-${ids++}',
      );

  setUp(() {
    ids = 0;
    world = FakeWorld(signedInAs: janinaId);
    world.replies.store['r0'] = reply(id: 'r0', authorId: meId, body: 'First');
  });

  test('loads the note and its replies in order', () async {
    final t = thread();
    await t.load();
    expect(t.note?.title, 'For Janina');
    expect(t.replies.map((r) => r.body), ['First']);
  });

  test('a sent reply is added only after the server saved it', () async {
    final t = thread();
    await t.load();

    final sent = await t.send('  Thank you.\n\nTruly.  ');
    expect(sent?.body, 'Thank you.\n\nTruly.');
    expect(sent?.authorId, janinaId);
    expect(t.replies.last.id, sent!.id);
    expect(world.replies.store.containsKey(sent.id), isTrue);
  });

  test('a failed send is reported and nothing is shown as sent', () async {
    final t = thread();
    await t.load();
    world.replies.nextFailure = const NoConnection();

    expect(await t.send('Hello'), isNull);
    expect(t.sendFailure, isA<NoConnection>());
    expect(t.replies, hasLength(1));
  });

  test('retrying the same text reuses its id, so it cannot duplicate', () async {
    final t = thread();
    await t.load();
    world.replies.nextFailure = const NoConnection();
    await t.send('Hello');
    world.replies.nextFailure = null;
    await t.send('Hello');

    expect(world.replies.sentIds, ['reply-0', 'reply-0']);
    expect(world.replies.store.values.where((r) => r.body == 'Hello'), hasLength(1));
  });

  test('double-tapping Send sends once', () async {
    final t = thread();
    await t.load();
    world.replies.gate = Completer();

    final first = t.send('Hi');
    final second = t.send('Hi');
    world.replies.gate!.complete();

    expect(await second, isNull);
    expect(await first, isNotNull);
    expect(world.replies.sendCalls, 1);
  });

  test('empty replies are ignored', () async {
    final t = thread();
    await t.load();
    expect(await t.send('   \n '), isNull);
    expect(world.replies.sendCalls, 0);
  });

  test('loads the entry\'s photos with it', () async {
    world.photos.seed('p1', 'n1');
    final t = thread();
    await t.load();
    expect(t.photos.map((p) => p.id), ['p1']);
  });

  test('a silent refresh picks up the other person\'s new reply', () async {
    final t = thread();
    await t.load();
    world.replies.addFrom(meId, 'n1', 'Another one');
    await t.load(silent: true);
    expect(t.replies.map((r) => r.body), ['First', 'Another one']);
  });

  test('a silent refresh that fails offline keeps the conversation', () async {
    final t = thread();
    await t.load();
    world.notes.nextFailure = const NoConnection();
    expect(await t.load(silent: true), isA<NoConnection>());
    expect(t.note, isNotNull);
    expect(t.failure, isNull);
  });

  test('a note moved back to drafts disappears for the other person', () async {
    final t = thread();
    await t.load();
    world.notes.store['n1'] = note(status: NoteStatus.draft);
    await t.load(silent: true);
    expect(t.note, isNull);
    expect(t.failure, isA<NoteNotFound>());
  });
}
