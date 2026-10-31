import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secret_diary/app.dart';
import 'package:secret_diary/core/errors/app_failure.dart';
import 'package:secret_diary/core/notifications/post_notifications.dart';
import 'package:secret_diary/core/sync/sync_service.dart';
import 'package:secret_diary/core/updates/releases.dart';
import 'package:secret_diary/core/utils/dates.dart';
import 'package:secret_diary/core/widgets/ornaments.dart';
import 'package:secret_diary/features/notes/models/note.dart';

import '../support/fakes.dart';

const phone = Size(411, 860);
const tablet = Size(1280, 800);

void main() {
  late FakeWorld world;

  Future<void> start(WidgetTester tester, {Size size = phone}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(LetterApp(dependencies: world.dependencies));
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester, String passcode) async {
    await tester.enterText(find.byKey(const Key('passcode-field')), passcode);
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-letter-button')));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  Future<void> openPost(WidgetTester tester, String id) => tapKey(tester, ValueKey('post-$id'));
  Future<void> compose(WidgetTester tester) => tapKey(tester, const Key('new-note-button'));

  setUp(() => world = FakeWorld(notes: [note()]));

  group('access', () {
    testWidgets('the passcode field accepts digits only', (tester) async {
      await start(tester);
      await tester.enterText(find.byKey(const Key('passcode-field')), '12ab34');
      final field = tester.widget<TextField>(find.byKey(const Key('passcode-field')));
      expect(field.controller!.text, '1234');
      expect(field.keyboardType, TextInputType.number);
    });

    testWidgets('a wrong passcode reveals nothing', (tester) async {
      await start(tester);
      await signIn(tester, '999999');
      expect(find.textContaining("That's not quite it"), findsOneWidget);
      expect(find.byKey(const Key('feed')), findsNothing);
    });

    testWidgets("Janina's passcode opens the feed as Janina", (tester) async {
      await start(tester);
      await signIn(tester, '135790');

      expect(find.byKey(const Key('feed')), findsOneWidget);
      expect(find.byKey(const ValueKey('post-n1')), findsOneWidget);
      expect(find.text('Jarvey'), findsOneWidget);
      expect(find.text('Oct 28'), findsOneWidget);
      expect(find.text('For Janina'), findsOneWidget);
      expect(world.sync.started, isTrue);
    });

    testWidgets('Lock (on the profile) signs out and returns to the passcode screen', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await tapKey(tester, const Key('nav-profile'));
      expect(find.byKey(const Key('profile-name')), findsOneWidget);
      await tapKey(tester, const Key('lock-button'));

      expect(find.byKey(const Key('passcode-field')), findsOneWidget);
      expect(world.auth.userId, isNull);
    });

    testWidgets('an expired session returns to the passcode screen with a notice', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      world.auth.expire();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('passcode-field')), findsOneWidget);
      expect(find.text(const SessionExpired().message), findsOneWidget);
    });
  });

  group('feed', () {
    testWidgets("shows both people's shared entries, newest post first", (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [
        note(id: 'a', title: 'Older', body: 'Older body', at: t0),
        note(id: 'b', authorId: janinaId, title: 'Newer', body: 'Newer body', at: t0.add(const Duration(hours: 1))),
      ]);
      await start(tester);

      final older = tester.getTopLeft(find.byKey(const ValueKey('post-a')));
      final newer = tester.getTopLeft(find.byKey(const ValueKey('post-b')));
      expect(newer.dy, lessThan(older.dy));
    });

    testWidgets('text-only entries show 6 lines in the feed, then See more', (tester) async {
      final long = List.generate(30, (i) => 'Line $i').join('\n');
      world = FakeWorld(signedInAs: janinaId, notes: [note(body: long)]);
      await start(tester);
      expect(tester.widget<Text>(find.byKey(const Key('note-body'))).maxLines, 6);
      expect(find.byKey(const Key('see-more')), findsOneWidget);

      await tapKey(tester, const Key('see-more'));
      expect(find.text('Entry'), findsOneWidget);
      expect(tester.widget<SelectableText>(find.byKey(const Key('note-body'))).data, long);
      expect(find.byKey(const Key('see-more')), findsNothing);
    });

    testWidgets('entries with photos show 2 lines, then See more', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [note(body: 'One\nTwo\nThree')]);
      world.photos.seed('p1', 'n1');
      await start(tester);
      expect(tester.widget<Text>(find.byKey(const Key('note-body'))).maxLines, 2);
      expect(find.byKey(const Key('see-more')), findsOneWidget);
    });

    testWidgets('on the profile the header scrolls away and the tabs stay on top', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [
        for (var i = 0; i < 12; i++)
          note(id: 'n$i', authorId: janinaId, body: 'Entry $i', at: t0.add(Duration(hours: i))),
      ]);
      await start(tester);
      await tapKey(tester, const Key('nav-profile'));
      expect(tester.getTopLeft(find.byKey(const Key('profile-name'))).dy, greaterThan(0));

      await tester.drag(find.byKey(const Key('profile')), const Offset(0, -500));
      await tester.pumpAndSettle();
      final name = find.byKey(const Key('profile-name'));
      expect(name.evaluate().isEmpty || tester.getBottomLeft(name).dy <= 0, isTrue);
      expect(tester.getTopLeft(find.byKey(const Key('tab-entries'))).dy, lessThan(80));
    });

    testWidgets('posts show the author\'s profile photo', (tester) async {
      await start(tester);
      expect(find.byKey(const Key('login-tagline')), findsOneWidget);

      await signIn(tester, '135790');
      expect(find.byKey(const ValueKey('avatar-photo-jarvey')), findsWidgets);
    });

    testWidgets('light mode is cream; dark mode is black', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      expect(Theme.of(tester.element(find.byKey(const Key('feed')))).scaffoldBackgroundColor,
          const Color(0xFFFEFAF3));

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byKey(const Key('feed')))).scaffoldBackgroundColor,
          const Color(0xFF000000));
    });

    test('people who share an initial still get different avatar colours', () {
      expect(Avatar.toneFor('Jarvey'), isNot(Avatar.toneFor('Janina')));
      expect(Avatar.toneFor('Janina'), Avatar.toneFor(' janina '));
    });

    testWidgets('the nav bar shrinks while scrolling down and returns on the way up', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [
        for (var i = 0; i < 12; i++) note(id: 'n$i', body: 'Entry $i', at: t0.add(Duration(hours: i))),
      ]);
      await start(tester);
      double scale() => tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
      expect(scale(), 1);

      await tester.drag(find.byKey(const Key('feed')), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(scale(), 0.8);
      await tapKey(tester, const Key('nav-profile')); // still tappable while small
      expect(find.byKey(const Key('profile-name')), findsOneWidget);
      expect(scale(), 1);

      await tapKey(tester, const Key('nav-home'));
      await tester.drag(find.byKey(const Key('feed')), const Offset(0, -300));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const Key('feed')), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(scale(), 1);
    });

    testWidgets('short entries have no See more', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [note(body: 'Just one line.')]);
      world.photos.seed('p1', 'n1');
      await start(tester);
      expect(find.byKey(const Key('see-more')), findsNothing);
    });

    testWidgets('the reply count is shown on the post', (tester) async {
      world.auth.userId = janinaId;
      world.replies.addFrom(meId, 'n1', 'one');
      world.replies.addFrom(janinaId, 'n1', 'two');
      await start(tester);
      expect(find.byKey(const ValueKey('reply-count-n1')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('reply-count-n1'))).data, '2');
    });

    testWidgets('an empty feed invites the first entry', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: []);
      await start(tester);
      expect(find.textContaining('No entries yet'), findsOneWidget);
    });

    testWidgets('a loading failure offers a retry', (tester) async {
      world.auth.userId = janinaId;
      world.notes.nextFailure = const NoConnection();
      await start(tester);
      expect(find.text(const NoConnection().message), findsOneWidget);

      world.notes.nextFailure = null;
      await tapKey(tester, const Key('center-action-button'));
      expect(find.byKey(const ValueKey('post-n1')), findsOneWidget);
    });

    testWidgets('on a wide screen the feed stays a narrow, centred column', (tester) async {
      world.auth.userId = janinaId;
      await start(tester, size: tablet);
      final post = tester.getRect(find.byKey(const ValueKey('post-n1')));
      expect(post.width, lessThanOrEqualTo(620));
      expect(post.center.dx, closeTo(640, 1));
    });

    testWidgets('a new entry from the other phone appears after a sync event', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      world.notes.store['n2'] = note(id: 'n2', body: 'Fresh from his phone', at: t0.add(const Duration(days: 3)));
      world.sync.emit(const SyncEvent(table: 'notes', noteId: 'n2'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Fresh from his phone'), findsOneWidget);
    });
  });

  group('notifications', () {
    Future<void> newEntryFrom(WidgetTester tester, String authorId, String id) async {
      world.notes.store[id] = note(
        id: id,
        authorId: authorId,
        title: '',
        body: 'Body of $id',
        at: t0.add(const Duration(days: 3)),
      );
      world.sync.emit(SyncEvent(table: 'notes', noteId: id));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    testWidgets('asks for permission, and counts what is on screen as seen', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      expect(world.notifications.permissionAsked, isTrue);
      expect(world.activity.calls, [false]);
    });

    testWidgets('in the background, changes from the other phone are announced', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await newEntryFrom(tester, meId, 'n2');
      expect(world.activity.calls.last, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(world.activity.calls.last, isFalse);
    });

    testWidgets('tapping a notification opens that entry', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      world.notifications.tapsController.add('n1');
      await tester.pumpAndSettle();
      expect(find.text('Entry'), findsOneWidget);
    });

    testWidgets('opening the app from a notification goes to that entry', (tester) async {
      world.auth.userId = janinaId;
      world.notifications.launchNoteId = 'n1';
      await start(tester);
      expect(find.text('Entry'), findsOneWidget);
    });

    testWidgets('notification text for each kind of activity', (tester) async {
      NewActivity of(ActivityKind kind, String text) => NewActivity(
        kind: kind,
        key: 'k',
        noteId: 'n1',
        actorName: 'Janina',
        text: text,
        at: t0,
      );
      expect(of(ActivityKind.post, 'Hello\nmore').title, 'Janina shared a new entry');
      expect(of(ActivityKind.post, 'Hello\nmore').body, 'Hello');
      expect(of(ActivityKind.post, '').body, 'Photos');
      expect(of(ActivityKind.reply, 'Aww').title, 'Janina replied');
      expect(of(ActivityKind.like, 'For you').title, 'Janina liked your entry');
    });

    testWidgets('profile offers to allow background running when Android restricts it', (tester) async {
      world.auth.userId = janinaId;
      world.background.unrestricted = false;
      await start(tester);
      await tapKey(tester, const Key('nav-profile'));
      await tapKey(tester, const Key('background-button'));
      expect(world.background.asked, 1);
    });
  });

  group('app lock', () {
    testWidgets('a phone with a screen lock asks to unlock on start', (tester) async {
      world.auth.userId = janinaId;
      world.screenLock.available = true;
      world.screenLock.succeed = false;
      await start(tester);
      expect(find.byKey(const Key('app-lock')), findsOneWidget);

      world.screenLock.succeed = true;
      await tapKey(tester, const Key('unlock-button'));
      expect(find.byKey(const Key('app-lock')), findsNothing);
      expect(find.byKey(const Key('feed')), findsOneWidget);
    });

    testWidgets('coming back after a while locks again; a quick switch does not', (tester) async {
      world.auth.userId = janinaId;
      world.screenLock.available = true;
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(LetterApp(dependencies: world.dependencies, lockAfter: Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-lock')), findsNothing); // unlocked on start

      world.screenLock.succeed = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-lock')), findsOneWidget);
    });

    testWidgets('no screen lock on the phone: no app lock, and signed out: no app lock', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      expect(find.byKey(const Key('app-lock')), findsNothing);
    });
  });

  group('entry page and replies', () {
    testWidgets('the reply button opens the entry with the reply box ready', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await tapKey(tester, const ValueKey('reply-n1'));

      expect(find.text('Entry'), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const Key('reply-field')));
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('replies are listed under the entry, oldest first', (tester) async {
      world.auth.userId = janinaId;
      world.replies.store['r1'] = reply(id: 'r1', authorId: meId, body: 'From Jarvey');
      world.replies.store['r2'] =
          reply(id: 'r2', authorId: janinaId, body: 'From Janina', at: t0.add(const Duration(hours: 2)));
      await start(tester);
      await openPost(tester, 'n1');

      expect(find.text('2 replies'), findsOneWidget);
      final first = tester.getTopLeft(find.byKey(const ValueKey('reply-r1')));
      final second = tester.getTopLeft(find.byKey(const ValueKey('reply-r2')));
      expect(first.dy, lessThan(second.dy));
      expect(find.text('Reply to Jarvey…'), findsOneWidget);
    });

    testWidgets('sending a reply saves it under the right entry', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await openPost(tester, 'n1');

      await tester.enterText(find.byKey(const Key('reply-field')), 'I read it.\n\nThank you.');
      await tester.pump();
      await tapKey(tester, const Key('reply-send-button'));

      final saved = world.replies.store.values.single;
      expect(saved.noteId, 'n1');
      expect(saved.authorId, janinaId);
      expect(find.text('I read it.\n\nThank you.'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('reply-field'))).controller!.text, isEmpty);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('reply-count-n1'))).data, '1');
    });

    testWidgets('a failed send keeps the text and says it was not sent', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await openPost(tester, 'n1');
      world.replies.nextFailure = const NoConnection();

      await tester.enterText(find.byKey(const Key('reply-field')), 'Hello');
      await tester.pump();
      await tapKey(tester, const Key('reply-send-button'));

      expect(find.byKey(const Key('reply-send-failure')), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('reply-field'))).controller!.text, 'Hello');
      expect(world.replies.store, isEmpty);
    });

    testWidgets('an unsent reply survives leaving and reopening the entry', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await openPost(tester, 'n1');
      await tester.enterText(find.byKey(const Key('reply-field')), 'Half a thought');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await openPost(tester, 'n1');
      expect(tester.widget<TextField>(find.byKey(const Key('reply-field'))).controller!.text, 'Half a thought');
    });

    testWidgets("the other person's reply appears after a sync event", (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await openPost(tester, 'n1');

      world.replies.addFrom(meId, 'n1', 'Sent from his phone');
      world.sync.emit(const SyncEvent(table: 'replies', noteId: 'n1'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('Sent from his phone'), findsOneWidget);
    });
  });

  group('writing', () {
    testWidgets('Janina posts an entry; it tops the feed under her name', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await compose(tester);

      expect(find.text('New entry'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('note-title-field')), 'For you, too');
      await tester.enterText(find.byKey(const Key('note-body-field')), 'My entry.');
      await tapKey(tester, const Key('publish-button'));

      final saved = world.notes.store.values.firstWhere((n) => n.title == 'For you, too');
      expect(saved.authorId, janinaId);
      expect(saved.status, NoteStatus.published);
      expect(find.byKey(const Key('feed')), findsOneWidget);
      final mine = tester.getTopLeft(find.byKey(ValueKey('post-${saved.id}')));
      final his = tester.getTopLeft(find.byKey(const ValueKey('post-n1')));
      expect(mine.dy, lessThan(his.dy));
    });

    testWidgets('only Jarvey can pick the day; Janina\'s entries are dated the day she posts', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await compose(tester);
      expect(find.byKey(const Key('entry-date-button')), findsNothing);
      await tester.enterText(find.byKey(const Key('note-body-field')), 'Today.');
      await tapKey(tester, const Key('publish-button'));
      final saved = world.notes.store.values.firstWhere((n) => n.body == 'Today.');
      expect(saved.entryDate, Dates.today());
    });

    testWidgets('Jarvey gets the date button in the composer', (tester) async {
      world.auth.userId = meId;
      await start(tester);
      await compose(tester);
      expect(find.byKey(const Key('entry-date-button')), findsOneWidget);
    });

    testWidgets('a draft goes to Drafts on the profile, not the feed', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await compose(tester);
      await tester.enterText(find.byKey(const Key('note-body-field')), 'Unfinished');
      await tapKey(tester, const Key('save-draft-button'));

      expect(find.byKey(const Key('profile-name')), findsOneWidget);
      await tapKey(tester, const Key('tab-drafts'));
      expect(find.text('Unfinished'), findsOneWidget);
      expect(find.text('Draft'), findsOneWidget);

      await tapKey(tester, const Key('nav-home'));
      expect(find.text('Unfinished'), findsNothing);
    });

    testWidgets('tapping a draft reopens it in the composer and Post shares it', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [
        note(),
        note(id: 'd', authorId: janinaId, status: NoteStatus.draft, body: 'Almost'),
      ]);
      await start(tester);
      await tapKey(tester, const Key('nav-profile'));
      await tapKey(tester, const Key('tab-drafts'));
      await openPost(tester, 'd');

      expect(find.text('Edit entry'), findsOneWidget);
      await tapKey(tester, const Key('publish-button'));
      expect(world.notes.store['d']!.status, NoteStatus.published);
    });

    testWidgets('cancelling with text asks: keep writing or save a draft', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await compose(tester);
      await tester.enterText(find.byKey(const Key('note-body-field')), 'Precious words');
      await tester.pump();

      await tapKey(tester, const Key('compose-cancel'));
      await tapKey(tester, const Key('keep-writing-button'));
      expect(find.text('Precious words'), findsOneWidget);

      await tapKey(tester, const Key('compose-cancel'));
      await tapKey(tester, const Key('save-draft-sheet-button'));
      final draft = world.notes.store.values.firstWhere((n) => n.body == 'Precious words');
      expect(draft.status, NoteStatus.draft);
    });

    testWidgets('discarding a new entry saves nothing', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await compose(tester);
      await tester.enterText(find.byKey(const Key('note-body-field')), 'Never mind');
      await tester.pump();
      await tapKey(tester, const Key('compose-cancel'));
      await tapKey(tester, const Key('discard-changes-button'));

      expect(find.byKey(const Key('feed')), findsOneWidget);
      expect(world.notes.writes, 0);
    });

    testWidgets('only the author gets the ··· menu on a post', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      expect(find.byKey(const ValueKey('post-menu-n1')), findsNothing);
    });

    testWidgets('the author edits from the entry page', (tester) async {
      world.auth.userId = meId;
      await start(tester);
      await openPost(tester, 'n1');
      await tapKey(tester, const ValueKey('post-menu-n1'));
      await tapKey(tester, const Key('edit-note-button'));

      await tester.enterText(find.byKey(const Key('note-body-field')), 'Rewritten entry.');
      await tapKey(tester, const Key('save-changes-button'));

      expect(world.notes.store['n1']!.body, 'Rewritten entry.');
      expect(find.text('Rewritten entry.'), findsWidgets);
    });

    testWidgets('an entry without a title shows just the text', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [note(title: '')]);
      await start(tester);
      expect(find.byKey(const Key('note-title')), findsNothing);
    });

    testWidgets('a backdated entry shows its own date and sits with that day in the feed', (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [
        note(id: 'aug', body: 'In August', entryDate: DateTime(2026, 8, 13), at: DateTime.utc(2026, 10, 31, 12)),
        note(id: 'oct', body: 'In October', entryDate: DateTime(2026, 10, 30), at: DateTime.utc(2026, 10, 30, 12)),
      ]);
      await start(tester);
      expect(find.text('Aug 13'), findsOneWidget);
      expect(find.text('Oct 30'), findsOneWidget);
      final oct = tester.getTopLeft(find.byKey(const ValueKey('post-oct')));
      final aug = tester.getTopLeft(find.byKey(const ValueKey('post-aug')));
      expect(oct.dy, lessThan(aug.dy));
    });
  });

  group('photos', () {
    testWidgets('an entry is posted with up to three photos', (tester) async {
      world.auth.userId = janinaId;
      world.picker.next = [picked(), picked(), picked(), picked()];
      await start(tester);
      await compose(tester);

      expect(find.text('0/3'), findsOneWidget);
      await tapKey(tester, const Key('add-photo-button'));
      expect(world.picker.requests.single.limit, 3);
      expect(find.text('3/3'), findsOneWidget);
      final gallery = tester.widget<IconButton>(
          find.descendant(of: find.byKey(const Key('add-photo-button')), matching: find.byType(IconButton)));
      expect(gallery.onPressed, isNull);

      await tester.enterText(find.byKey(const Key('note-body-field')), 'A good day.');
      await tapKey(tester, const Key('publish-button'));

      final saved = world.notes.store.values.firstWhere((n) => n.body == 'A good day.');
      expect(saved.status, NoteStatus.published);
      final photos = world.photos.store.values.where((p) => p.noteId == saved.id).toList();
      expect(photos, hasLength(3));
      photos.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      expect(find.byKey(ValueKey('photo-${photos.first.id}')), findsOneWidget);
      // The row scrolls sideways to the last one.
      await tester.dragUntilVisible(
        find.byKey(ValueKey('photo-${photos.last.id}')),
        find.byKey(ValueKey('photo-${photos.first.id}')),
        const Offset(-200, 0),
      );
      expect(find.byKey(ValueKey('photo-${photos.last.id}')), findsOneWidget);
    });

    testWidgets('removing a picked photo frees its slot', (tester) async {
      world.auth.userId = janinaId;
      world.picker.next = [picked(), picked()];
      await start(tester);
      await compose(tester);
      await tapKey(tester, const Key('add-photo-button'));
      expect(find.text('2/3'), findsOneWidget);

      await tester.tap(find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('remove-photo-')).first);
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('cancelling with only new photos still asks first', (tester) async {
      world.auth.userId = janinaId;
      world.picker.next = [picked()];
      await start(tester);
      await compose(tester);
      await tapKey(tester, const Key('add-camera-button'));
      expect(world.picker.requests.single.source.name, 'camera');

      await tapKey(tester, const Key('compose-cancel'));
      expect(find.byKey(const Key('discard-changes-button')), findsOneWidget);
    });

    testWidgets('the other person sees the photos in the feed and full screen', (tester) async {
      world.auth.userId = janinaId;
      world.photos.seed('p1', 'n1');
      world.photos.seed('p2', 'n1');
      await start(tester);

      expect(find.byKey(const ValueKey('photo-p1')), findsOneWidget);
      await tapKey(tester, const ValueKey('photo-p2'));
      expect(find.byKey(const Key('photo-viewer')), findsOneWidget);
      expect(find.text('2 of 2'), findsOneWidget);
    });

    testWidgets("photos of the other person's draft are never shown", (tester) async {
      world = FakeWorld(signedInAs: janinaId, notes: [
        note(),
        note(id: 'd', status: NoteStatus.draft, at: t0.add(const Duration(hours: 1))),
      ]);
      world.photos.seed('secret', 'd');
      await start(tester);
      expect(find.byKey(const ValueKey('photo-secret')), findsNothing);
      expect(find.byKey(const ValueKey('post-d')), findsNothing);
    });

    testWidgets('the author edits an entry, keeping its photo and adding one', (tester) async {
      world.auth.userId = meId;
      world.photos.seed('p1', 'n1');
      world.picker.next = [picked()];
      await start(tester);

      await tapKey(tester, const ValueKey('post-menu-n1'));
      await tapKey(tester, const Key('edit-note-button'));
      expect(find.byKey(const ValueKey('editor-photo-p1')), findsOneWidget);
      await tapKey(tester, const Key('add-photo-button'));
      expect(world.picker.requests.single.limit, 2);
      await tapKey(tester, const Key('save-changes-button'));

      expect(world.photos.store.values.where((p) => p.noteId == 'n1'), hasLength(2));
      expect(find.byKey(const ValueKey('photo-p1')), findsOneWidget);
    });

    testWidgets('a failed photo upload keeps the composer open with the photo', (tester) async {
      world.auth.userId = janinaId;
      world.picker.next = [picked()];
      await start(tester);
      await compose(tester);
      await tapKey(tester, const Key('add-photo-button'));
      await tester.enterText(find.byKey(const Key('note-body-field')), 'Text');
      world.photos.failAddNumber = 1;
      await tapKey(tester, const Key('publish-button'));

      expect(find.textContaining("a photo didn't upload"), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(world.notes.store.values.firstWhere((n) => n.body == 'Text').status, NoteStatus.draft);

      await tapKey(tester, const Key('publish-button'));
      expect(find.byKey(const Key('feed')), findsOneWidget);
      expect(world.photos.store, hasLength(1));
    });
  });

  group('replies: editing and deleting', () {
    testWidgets('you can edit your own reply; it says Edited', (tester) async {
      world.auth.userId = janinaId;
      world.replies.store['r1'] = reply();
      await start(tester);
      await openPost(tester, 'n1');
      await tapKey(tester, const ValueKey('reply-menu-r1'));
      await tapKey(tester, const Key('edit-reply-button'));
      await tester.enterText(find.byKey(const Key('edit-reply-field')), 'Thank you, truly.');
      await tapKey(tester, const Key('save-reply-button'));

      expect(world.replies.store['r1']!.body, 'Thank you, truly.');
      expect(find.text('Thank you, truly.'), findsOneWidget);
      expect(find.textContaining('Edited'), findsWidgets);
    });

    testWidgets('you can delete your own reply after confirming', (tester) async {
      world.auth.userId = janinaId;
      world.replies.store['r1'] = reply();
      await start(tester);
      await openPost(tester, 'n1');
      await tapKey(tester, const ValueKey('reply-menu-r1'));
      await tapKey(tester, const Key('delete-reply-button'));
      await tapKey(tester, const Key('confirm-delete-reply-button'));

      expect(world.replies.store.containsKey('r1'), isFalse);
      expect(find.byKey(const ValueKey('reply-r1')), findsNothing);
    });

    testWidgets("the other person's replies have no menu", (tester) async {
      world.auth.userId = meId;
      world.replies.store['r1'] = reply(); // from Janina
      await start(tester);
      await openPost(tester, 'n1');
      expect(find.byKey(const ValueKey('reply-menu-r1')), findsNothing);
    });
  });

  group('composer keeps unsaved text', () {
    testWidgets('text typed in a new entry comes back after closing the app', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await compose(tester);
      await tester.enterText(find.byKey(const Key('note-body-field')), 'Half a thought');
      await tester.pump(const Duration(seconds: 1));
      expect(world.store.values['compose_unsaved'], contains('Half a thought'));

      // The app is closed and opened again.
      await tester.pumpWidget(const SizedBox());
      await start(tester);
      await compose(tester);
      expect(find.text('Half a thought'), findsOneWidget);
    });

    testWidgets('posting forgets the kept text', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await compose(tester);
      await tester.enterText(find.byKey(const Key('note-body-field')), 'Done.');
      await tester.pump(const Duration(seconds: 1));
      await tapKey(tester, const Key('publish-button'));
      expect(world.store.values.containsKey('compose_unsaved'), isFalse);
    });
  });

  group('feed extras', () {
    testWidgets('offline: the saved copy is shown with a notice', (tester) async {
      world.auth.userId = janinaId;
      await start(tester); // saves a copy
      await tester.pumpWidget(const SizedBox());
      world.notes.nextFailure = const NoConnection();
      await start(tester);
      expect(find.byKey(const Key('offline-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('post-n1')), findsOneWidget);
    });

    testWidgets('a newer release is offered at the top of the feed', (tester) async {
      world.auth.userId = janinaId;
      world.releases.release = const AppRelease(versionCode: 2, versionName: '1.0.1', apkUrl: 'https://example.com/a.apk');
      await start(tester);
      expect(find.text('Version 1.0.1 is available'), findsOneWidget);
    });

    testWidgets('the same or an older release is not offered', (tester) async {
      world.auth.userId = janinaId;
      world.releases.release = const AppRelease(versionCode: 1, versionName: '1.0.0', apkUrl: 'https://example.com/a.apk');
      await start(tester);
      expect(find.byKey(const Key('update-banner')), findsNothing);
    });

    testWidgets("the other person's entries since your last visit get a dot until opened", (tester) async {
      world.auth.userId = janinaId;
      world.store.values['feed_visited_at'] = t0.subtract(const Duration(days: 1)).toIso8601String();
      await start(tester);
      expect(find.byKey(const ValueKey('new-dot-n1')), findsOneWidget);
      await openPost(tester, 'n1');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-dot-n1')), findsNothing);
    });

    testWidgets('the calendar shows entries for the chosen day', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await tapKey(tester, const Key('calendar-button'));
      expect(find.byKey(const Key('calendar')), findsOneWidget);
      // n1 is dated Oct 28, 2026.
      while (!find.text('October 2026').evaluate().isNotEmpty) {
        final month = tester.widget<Text>(find.byKey(const Key('calendar-month'))).data!;
        final forward = int.parse(month.split(' ').last) < 2026 ||
            (month.startsWith('Jan') || month.startsWith('Feb')) && month.endsWith('2026');
        await tapKey(tester, Key(forward ? 'next-month' : 'previous-month'));
      }
      await tapKey(tester, const ValueKey('calendar-day-2026-10-28'));
      expect(find.byKey(const ValueKey('calendar-entry-n1')), findsOneWidget);
    });

    testWidgets('"On this day" shows entries from this day in earlier years', (tester) async {
      final now = DateTime.now();
      world = FakeWorld(signedInAs: janinaId, notes: [
        note(id: 'old', body: 'A year ago today', entryDate: DateTime(now.year - 1, now.month, now.day)),
      ]);
      await start(tester);
      expect(find.byKey(const Key('on-this-day')), findsOneWidget);
      expect(find.textContaining('1 year ago'), findsOneWidget);
    });
  });

  group('likes', () {
    testWidgets('tapping the heart likes and unlikes', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      expect(find.byKey(const ValueKey('like-count-n1')), findsNothing);

      await tapKey(tester, const ValueKey('like-n1'));
      expect(world.notes.likes['n1'], {janinaId});
      expect(tester.widget<Text>(find.byKey(const ValueKey('like-count-n1'))).data, '1');
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

      await tapKey(tester, const ValueKey('like-n1'));
      expect(world.notes.likes['n1'], isEmpty);
      expect(find.byKey(const ValueKey('like-count-n1')), findsNothing);
    });

    testWidgets("both people's likes are counted", (tester) async {
      world.auth.userId = janinaId;
      world.notes.likes['n1'] = {meId};
      await start(tester);
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget); // not liked by her yet
      await tapKey(tester, const ValueKey('like-n1'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('like-count-n1'))).data, '2');
    });

    testWidgets('a like that fails is undone and explained', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      world.notes.nextFailure = const NoConnection();
      await tapKey(tester, const ValueKey('like-n1'));

      expect(find.byKey(const ValueKey('like-count-n1')), findsNothing);
      expect(find.text(const NoConnection().message), findsOneWidget);
    });

    testWidgets('liking from the entry page shows in the feed afterwards', (tester) async {
      world.auth.userId = janinaId;
      await start(tester);
      await openPost(tester, 'n1');
      await tapKey(tester, const ValueKey('like-n1'));
      expect(world.notes.likes['n1'], {janinaId});

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('like-count-n1'))).data, '1');
    });
  });

  group('deleting', () {
    Future<void> deleteFromMenu(WidgetTester tester, String id) async {
      await tapKey(tester, ValueKey('post-menu-$id'));
      await tapKey(tester, const Key('delete-note-button'));
    }

    testWidgets('the author deletes an entry and its photos after confirming', (tester) async {
      world.auth.userId = meId;
      final photo = world.photos.seed('p1', 'n1');
      await start(tester);

      await deleteFromMenu(tester, 'n1');
      expect(find.text('Delete entry?'), findsOneWidget);
      await tapKey(tester, const Key('confirm-delete-button'));

      expect(world.notes.deleted, ['n1']);
      expect(world.photos.removedFiles, [photo.storagePath]);
      expect(find.byKey(const ValueKey('post-n1')), findsNothing);
      expect(find.text('Entry deleted'), findsOneWidget);
    });

    testWidgets('cancelling keeps the entry', (tester) async {
      world.auth.userId = meId;
      await start(tester);
      await deleteFromMenu(tester, 'n1');
      await tapKey(tester, const Key('cancel-delete-button'));

      expect(world.notes.deleted, isEmpty);
      expect(find.byKey(const ValueKey('post-n1')), findsOneWidget);
    });

    testWidgets('deleting from the entry page goes back to the feed', (tester) async {
      world.auth.userId = meId;
      await start(tester);
      await openPost(tester, 'n1');
      await deleteFromMenu(tester, 'n1');
      await tapKey(tester, const Key('confirm-delete-button'));

      expect(find.byKey(const Key('feed')), findsOneWidget);
      expect(find.byKey(const ValueKey('post-n1')), findsNothing);
    });

    testWidgets('a failed delete keeps the entry and says why', (tester) async {
      world.auth.userId = meId;
      await start(tester);
      world.notes.nextFailure = const NoConnection();
      await deleteFromMenu(tester, 'n1');
      await tapKey(tester, const Key('confirm-delete-button'));

      expect(find.byKey(const ValueKey('post-n1')), findsOneWidget);
      expect(find.text(const NoConnection().message), findsOneWidget);
    });
  });
}
