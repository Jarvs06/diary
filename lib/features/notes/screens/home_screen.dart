import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_dependencies.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/updates/releases.dart';
import '../../../core/widgets/ornaments.dart';
import '../../access/screens/passcode_screen.dart';
import '../models/note.dart';
import '../services/notes_controller.dart';
import '../widgets/post_view.dart';
import 'calendar_screen.dart';
import 'compose_screen.dart';
import 'post_screen.dart';

/// Main screen, Threads-style: the shared feed and your profile, with a
/// bottom bar (Home · New entry · Profile).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AppDependencies get _deps => widget.dependencies;

  late final NotesController _notes = NotesController(
    notes: _deps.notesRepository,
    participants: _deps.participantsRepository,
    photos: _deps.photosRepository,
    currentUserId: _deps.authSession.userId,
    store: _deps.localStore,
  );

  /// Unsent reply text per entry, kept while moving around the app.
  final _replyDrafts = <String, String>{};
  final _feedScroll = ScrollController();
  int _tab = 0;

  /// The nav bar shrinks while you scroll down and comes back on the way up.
  bool _navCompact = false;
  StreamSubscription<void>? _syncSub;
  StreamSubscription<void>? _signedOutSub;
  StreamSubscription<String>? _tapSub;

  /// Entries the other person posted after you last opened the feed get a
  /// dot until you open them.
  DateTime? _newSince;
  final _opened = <String>{};
  static const _visitKey = 'feed_visited_at';

  /// A newer APK than this one, offered at the top of the feed.
  AppRelease? _update;

  /// False when Android may stop the background check to save battery.
  bool _backgroundOk = true;
  Timer? _syncDebounce;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notes.addListener(_onNotesChanged);
    _start();
    _deps.notifications.requestPermission();
    _tapSub = _deps.notifications.taps.listen(_openById);
    _deps.syncService.start();
    _syncSub = _deps.syncService.events.listen((_) {
      // Bursts of changes (e.g. share + photos) collapse into one refresh.
      _syncDebounce?.cancel();
      _syncDebounce = Timer(const Duration(milliseconds: 400), () => _refresh());
    });
    _signedOutSub = _deps.authSession.onSignedOut.listen(
      (_) => _goToPasscode(notice: const SessionExpired()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncDebounce?.cancel();
    _syncSub?.cancel();
    _signedOutSub?.cancel();
    _tapSub?.cancel();
    _deps.syncService.stop();
    _notes.removeListener(_onNotesChanged);
    _notes.dispose();
    _feedScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _checkBackground();
    }
  }

  Future<void> _start() async {
    final visited = DateTime.tryParse(await _deps.localStore.read(_visitKey) ?? '');
    if (mounted) setState(() => _newSince = visited);
    await _notes.load();
    if (_notes.failure == null && !_notes.isOffline) {
      await _deps.localStore.write(_visitKey, DateTime.now().toUtc().toIso8601String());
    }
    await _afterFirstLoad();
    unawaited(_checkForUpdate());
    unawaited(_checkBackground());
  }

  Future<void> _checkForUpdate() async {
    final latest = await _deps.releases.latest();
    if (latest != null && latest.versionCode > _deps.buildNumber && mounted) {
      setState(() => _update = latest);
    }
  }

  Future<void> _checkBackground() async {
    final ok = await _deps.backgroundRunning.isUnrestricted();
    if (mounted && ok != _backgroundOk) setState(() => _backgroundOk = ok);
  }

  bool _onScroll(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final compact = switch (n.direction) {
      ScrollDirection.reverse => true,
      ScrollDirection.forward => false,
      ScrollDirection.idle => n.metrics.pixels > 0 && _navCompact,
    };
    if (compact != _navCompact) setState(() => _navCompact = compact);
    return false;
  }

  Future<void> _afterFirstLoad() async {
    await _catchUpNotifications();
    final launchedFor = await _deps.notifications.takeLaunchNoteId();
    if (launchedFor != null) await _openById(launchedFor);
  }

  /// While you're looking at the app, everything counts as seen. When it's
  /// in the background (but still running), the other person's new entries,
  /// replies and likes are announced as phone notifications instead.
  Future<void> _catchUpNotifications() async {
    if (_notes.failure != null || _notes.isOffline) return;
    final state = WidgetsBinding.instance.lifecycleState;
    final foreground = state == null || state == AppLifecycleState.resumed;
    try {
      await _deps.activity.catchUp(announce: !foreground);
    } catch (_) {
      // Offline or similar: the next check catches up.
    }
  }

  /// Opens the entry a tapped notification was about.
  Future<void> _openById(String id) async {
    var note = _notes.feed.where((n) => n.id == id).firstOrNull;
    if (note == null) {
      await _notes.refresh();
      note = _notes.feed.where((n) => n.id == id).firstOrNull;
    }
    if (note == null || !mounted) return;
    setState(() => _tab = 0);
    await _open(note);
  }

  void _onNotesChanged() {
    if (_notes.failure is SessionExpired) _deps.authSession.signOut();
  }

  /// With [userInitiated], a connection problem is mentioned briefly; what's
  /// on screen stays.
  Future<void> _refresh({bool userInitiated = false}) async {
    final failure = await _notes.refresh();
    if (failure == null) await _catchUpNotifications();
    if (failure is SessionExpired) {
      await _deps.authSession.signOut();
    } else if (failure != null && userInitiated && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  Future<void> _compose({Note? existing}) async {
    // A tall sheet over the feed, as on Threads. Dragging it down is off so
    // a half-written entry can't be swiped away; Cancel, back and tapping
    // outside all go through the composer's "save draft / discard" check.
    final saved = await showModalBottomSheet<Note>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: false,
      backgroundColor: context.colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: context.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.95,
        child: ComposeScreen(
          dependencies: _deps,
          me: _notes.me?.displayName ?? '',
          existing: existing,
          existingPhotos: existing == null ? const [] : _notes.photosOf(existing.id),
          canPickDay: _notes.me?.key == 'author',
        ),
      ),
    );
    if (saved == null || !mounted) return;
    _notes.applySaved(saved);
    unawaited(_notes.refresh());
    if (saved.isDraft) {
      setState(() => _tab = 1);
    } else {
      setState(() => _tab = 0);
      if (_feedScroll.hasClients) _feedScroll.jumpTo(0);
    }
  }

  /// Opens an entry's page; with [reply], straight into the reply box.
  Future<void> _open(Note note, {bool reply = false}) async {
    setState(() => _opened.add(note.id));
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PostScreen(
          dependencies: _deps,
          notes: _notes,
          noteId: note.id,
          replyDrafts: _replyDrafts,
          startReplying: reply,
          onEdit: (latest) => _compose(existing: latest),
          onDelete: _delete,
        ),
      ),
    );
    if (mounted) unawaited(_notes.refresh());
  }

  Future<void> _lock() async {
    _goToPasscode();
    await _deps.authSession.signOut();
  }

  void _goToPasscode({AppFailure? notice}) {
    if (_leaving || !mounted) return;
    _leaving = true;
    Navigator.of(context).pushAndRemoveUntil(
      FadeRoute(
        builder: (_) => PasscodeScreen(dependencies: _deps, notice: notice),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The feed scrolls underneath the floating bar, like Threads.
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: _notes,
          builder: (context, _) {
            if (_notes.isLoading) {
              return const Center(child: CircularProgressIndicator(strokeWidth: 2));
            }
            final failure = _notes.failure;
            if (failure != null) {
              final notParticipant = failure is NotAllowed;
              return CenteredMessage(
                message: notParticipant ? "This account isn't part of this space." : failure.message,
                actionLabel: notParticipant ? 'Lock' : 'Try again',
                onAction: notParticipant ? _lock : _notes.load,
              );
            }
            return NotificationListener<UserScrollNotification>(
              onNotification: _onScroll,
              child: IndexedStack(index: _tab, children: [_feed(), _profile()]),
            );
          },
        ),
      ),
      bottomNavigationBar: _BottomBar(
        tab: _tab,
        compact: _navCompact,
        onHome: () {
          if (_tab == 0 && _feedScroll.hasClients) {
            _feedScroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          }
          setState(() {
            _tab = 0;
            _navCompact = false;
          });
        },
        onCompose: () => _compose(),
        onProfile: () => setState(() {
          _tab = 1;
          _navCompact = false;
        }),
      ),
    );
  }

  Widget _post(Note note) {
    final mine = _notes.isMine(note.authorId);
    final since = _newSince;
    return PostView(
      note: note,
      isNew: since != null && !mine && note.postedAt.isAfter(since) && !_opened.contains(note.id),
      authorName: _notes.nameOf(note.authorId),
      photos: _notes.photosOf(note.id),
      loadPhoto: _deps.photosRepository.loadPhoto,
      liked: note.isLikedBy(_notes.meId),
      onTap: () => note.isDraft ? _compose(existing: note) : _open(note),
      onLike: note.isDraft ? null : () => _like(note),
      onReply: note.isDraft ? null : () => _open(note, reply: true),
      onEdit: mine ? () => _compose(existing: note) : null,
      onDelete: mine ? () => _delete(note) : null,
    );
  }

  Future<void> _like(Note note) async {
    final failure = await _notes.toggleLike(note);
    if (failure != null) _notice(failure);
  }

  /// Asks first, then deletes. Returns true if the entry is gone.
  Future<bool> _delete(Note note) async {
    final confirmed = await confirmDelete(context);
    if (!confirmed || !mounted) return false;
    final failure = await _notes.delete(note);
    if (failure != null) {
      _notice(failure);
      return false;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Entry deleted')));
    }
    return true;
  }

  void _notice(AppFailure failure) {
    if (failure is SessionExpired) {
      _deps.authSession.signOut();
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failure.message)));
  }

  Widget _feed() {
    final feed = _notes.feed;
    return RefreshIndicator(
      onRefresh: () => _refresh(userInitiated: true),
      child: CustomScrollView(
        key: const Key('feed'),
        controller: _feedScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const BrandTitle(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      key: const Key('calendar-button'),
                      tooltip: 'Calendar',
                      icon: const Icon(Icons.calendar_month_outlined),
                      onPressed: _openCalendar,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_notes.isOffline) SliverToBoxAdapter(child: ReadableWidth(child: _offlineBanner())),
          if (_update != null) SliverToBoxAdapter(child: ReadableWidth(child: _updateBanner(_update!))),
          SliverToBoxAdapter(child: ReadableWidth(child: _composePrompt())),
          const SliverToBoxAdapter(child: Divider()),
          if (_onThisDay(feed).isNotEmpty)
            SliverToBoxAdapter(child: ReadableWidth(child: _onThisDayCard(_onThisDay(feed)))),
          if (feed.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: CenteredMessage(
                icon: Icons.edit_note_rounded,
                message: 'No entries yet.\nTap + to write the first one.',
              ),
            )
          else
            SliverList.separated(
              itemCount: feed.length,
              separatorBuilder: (_, _) => const ReadableWidth(child: Divider()),
              itemBuilder: (_, i) => ReadableWidth(child: _post(feed[i])),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: _BottomBar.clearance)),
        ],
      ),
    );
  }

  void _openCalendar() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CalendarScreen(notes: _notes, onOpen: (note) => _open(note)),
      ),
    );
  }

  /// Entries from this day in earlier years.
  List<Note> _onThisDay(List<Note> feed) {
    final today = DateTime.now();
    return feed
        .where(
          (n) =>
              n.entryDate.month == today.month &&
              n.entryDate.day == today.day &&
              n.entryDate.year < today.year,
        )
        .toList();
  }

  Widget _onThisDayCard(List<Note> notes) {
    return Container(
      key: const Key('on-this-day'),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('On this day', style: context.text.titleSmall),
          for (final n in notes)
            InkWell(
              onTap: () => _open(n),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${DateTime.now().year - n.entryDate.year} '
                  '${DateTime.now().year - n.entryDate.year == 1 ? 'year' : 'years'} ago · '
                  '${_notes.nameOf(n.authorId)}: ${n.hasTitle ? n.title : n.body.split('\n').first}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodyMedium?.copyWith(color: context.muted),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _offlineBanner() {
    return Padding(
      key: const Key('offline-banner'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 18, color: context.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "You're offline. Showing the entries saved on this phone.",
              style: context.text.bodySmall?.copyWith(color: context.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _updateBanner(AppRelease release) {
    return Container(
      key: const Key('update-banner'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              release.versionName.isEmpty
                  ? 'A new version is available'
                  : 'Version ${release.versionName} is available',
              style: context.text.bodyMedium,
            ),
          ),
          TextButton(
            key: const Key('update-button'),
            onPressed: () => launchUrl(Uri.parse(release.apkUrl), mode: LaunchMode.externalApplication),
            child: const Text('Update'),
          ),
          IconButton(
            tooltip: 'Not now',
            icon: Icon(Icons.close, size: 18, color: context.muted),
            onPressed: () => setState(() => _update = null),
          ),
        ],
      ),
    );
  }

  /// "What's new?" under the header, as on Threads: tap to write.
  Widget _composePrompt() {
    final name = _notes.me?.displayName ?? '';
    return InkWell(
      key: const Key('feed-compose-prompt'),
      onTap: () => _compose(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Row(
          children: [
            Avatar(name: name, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: context.text.titleSmall),
                  const SizedBox(height: 2),
                  Text("What's new?", style: context.text.bodyLarge?.copyWith(color: context.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Your name and entries. The header scrolls away with the list so there
  /// is more room to read; the Entries / Drafts tabs stay pinned on top.
  Widget _profile() {
    final me = _notes.me;
    final name = me?.displayName ?? '';
    final entries = _notes.myEntries;
    final drafts = _notes.myDrafts;

    Widget list(String key, List<Note> notes, String empty) => Builder(
      builder: (context) => RefreshIndicator(
        onRefresh: () => _refresh(userInitiated: true),
        child: CustomScrollView(
          key: PageStorageKey(key),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverOverlapInjector(handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context)),
            if (notes.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: CenteredMessage(message: empty))
            else
              SliverList.separated(
                itemCount: notes.length,
                separatorBuilder: (_, _) => const ReadableWidth(child: Divider()),
                itemBuilder: (_, i) => ReadableWidth(child: _post(notes[i])),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: _BottomBar.clearance)),
          ],
        ),
      ),
    );

    return DefaultTabController(
      length: 2,
      child: NestedScrollView(
        key: const Key('profile'),
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: ReadableWidth(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name, key: const Key('profile-name'), style: context.text.headlineSmall),
                              const SizedBox(height: 4),
                              Text(
                                entries.length == 1 ? '1 entry' : '${entries.length} entries',
                                style: context.text.bodyMedium?.copyWith(color: context.muted),
                              ),
                            ],
                          ),
                        ),
                        Avatar(name: name, size: 64),
                      ],
                    ),
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      key: const Key('lock-button'),
                      onPressed: _lock,
                      icon: const Icon(Icons.lock_outline, size: 18),
                      label: const Text('Lock'),
                    ),
                    if (!_backgroundOk) ...[
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const Key('background-button'),
                        onPressed: _deps.backgroundRunning.askUnrestricted,
                        icon: const Icon(Icons.notifications_active_outlined, size: 18),
                        label: const Text('Allow notifications in the background'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          SliverOverlapAbsorber(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            sliver: SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedTabs(
                color: context.colors.surface,
                tabBar: TabBar(
                  tabs: [
                    const Tab(key: Key('tab-entries'), text: 'Entries'),
                    Tab(
                      key: const Key('tab-drafts'),
                      text: drafts.isEmpty ? 'Drafts' : 'Drafts (${drafts.length})',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        body: TabBarView(
          children: [
            list('profile-entries', entries, "You haven't shared anything yet."),
            list('profile-drafts', drafts, 'No drafts.'),
          ],
        ),
      ),
    );
  }
}

/// Keeps the profile's Entries / Drafts tabs on screen while the header
/// above them scrolls away.
class _PinnedTabs extends SliverPersistentHeaderDelegate {
  _PinnedTabs({required this.tabBar, required this.color});

  final TabBar tabBar;
  final Color color;

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => ColoredBox(
    color: color,
    child: ReadableWidth(child: tabBar),
  );

  @override
  bool shouldRebuild(_PinnedTabs old) => old.tabBar != tabBar || old.color != color;
}

/// Threads-style floating navigation: a frosted, rounded pill with three
/// icons. The selected tab sits in a soft inner pill. While [compact] it
/// shrinks to 80% of its size, anchored to the bottom edge.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.tab,
    required this.compact,
    required this.onHome,
    required this.onCompose,
    required this.onProfile,
  });

  /// Space lists leave at the bottom so their last item clears the bar.
  static const clearance = 110.0;

  static const compactScale = 0.8;

  final int tab;
  final bool compact;
  final VoidCallback onHome;
  final VoidCallback onCompose;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final light = Theme.of(context).brightness == Brightness.light;
    Widget item({
      required Key key,
      required String label,
      required String asset,
      required VoidCallback onTap,
      bool selected = false,
    }) => Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Tooltip(
          message: label,
          child: InkWell(
            key: key,
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 52,
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: selected ? colors.primary.withValues(alpha: light ? 0.35 : 0.08) : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: AssetIcon(
                asset,
                size: 26,
                color: selected ? colors.onSurface : colors.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
      ),
    );

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: AnimatedScale(
        scale: compact ? compactScale : 1,
        alignment: Alignment.bottomCenter,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: Center(
          heightFactor: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  shape: const StadiumBorder(),
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipPath(
                  clipper: const ShapeBorderClipper(shape: StadiumBorder()),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: ShapeDecoration(
                        color: colors.surface.withValues(alpha: 0.4),
                        shape: StadiumBorder(side: BorderSide(color: context.hairline)),
                      ),
                      child: Row(
                        children: [
                          item(
                            key: const Key('nav-home'),
                            label: 'Home',
                            asset: AppAssets.navHome,
                            selected: tab == 0,
                            onTap: onHome,
                          ),
                          item(
                            key: const Key('new-note-button'),
                            label: 'New entry',
                            asset: AppAssets.navPlus,
                            onTap: onCompose,
                          ),
                          item(
                            key: const Key('nav-profile'),
                            label: 'Profile',
                            asset: AppAssets.navProfile,
                            selected: tab == 1,
                            onTap: onProfile,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
