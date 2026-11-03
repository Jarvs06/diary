import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_dependencies.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ornaments.dart';
import '../../photos/models/photo.dart';
import '../../photos/services/photo_picker.dart';
import '../../replies/models/reply.dart';
import '../../replies/services/thread_controller.dart';
import '../../replies/widgets/reply_composer.dart';
import '../../replies/widgets/reply_tile.dart';
import '../models/note.dart';
import '../services/notes_controller.dart';
import '../widgets/post_view.dart';

/// One entry on its own page: the whole post, its replies underneath, and
/// a reply bar at the bottom. Keeps itself up to date with Realtime.
class PostScreen extends StatefulWidget {
  const PostScreen({
    super.key,
    required this.dependencies,
    required this.notes,
    required this.noteId,
    required this.replyDrafts,
    required this.onEdit,
    required this.onDelete,
    this.startReplying = false,
  });

  final AppDependencies dependencies;

  /// For names and who "me" is.
  final NotesController notes;
  final String noteId;

  /// Unsent reply text per entry, owned by the home screen.
  final Map<String, String> replyDrafts;
  final Future<void> Function(Note latest) onEdit;

  /// Asks, deletes, and returns true if the entry is gone.
  final Future<bool> Function(Note note) onDelete;

  /// Put the cursor in the reply box as soon as the entry is shown.
  final bool startReplying;

  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> with WidgetsBindingObserver {
  AppDependencies get _deps => widget.dependencies;
  NotesController get _people => widget.notes;

  late final ThreadController _thread = ThreadController(
    noteId: widget.noteId,
    notes: _deps.notesRepository,
    replies: _deps.repliesRepository,
    photos: _deps.photosRepository,
  )..load();
  late final _composer = TextEditingController(text: widget.replyDrafts[widget.noteId] ?? '');
  final _scroll = ScrollController();
  final _replyFocus = FocusNode();
  late bool _focusReplyOnLoad = widget.startReplying;

  /// The top-level reply being answered, if any.
  Reply? _answering;
  PickedPhoto? _photo;

  /// Top-level replies whose answers are shown.
  final _expanded = <String>{};
  StreamSubscription<void>? _syncSub;
  Timer? _debounce;
  int _seenReplies = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _composer.addListener(() => widget.replyDrafts[widget.noteId] = _composer.text);
    _thread.addListener(_onThreadChanged);
    _syncSub = _deps.syncService.events.listen((event) {
      if (event.noteId != null && event.noteId != widget.noteId) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), _reload);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _syncSub?.cancel();
    _thread.removeListener(_onThreadChanged);
    _thread.dispose();
    _composer.dispose();
    _replyFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  Future<void> _reload({bool userInitiated = false}) async {
    final failure = await _thread.load(silent: true);
    if (failure is SessionExpired) {
      await _deps.authSession.signOut();
    } else if (failure != null && userInitiated && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  /// A new reply from the other person is followed only if you're already
  /// reading the end of the conversation.
  void _onThreadChanged() {
    final loaded = _thread.note;
    if (loaded != null) unawaited(_people.markSeen(loaded));
    if (_focusReplyOnLoad && _thread.note != null && !_thread.note!.isDraft) {
      _focusReplyOnLoad = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _replyFocus.requestFocus();
      });
    }
    final all = _thread.replies;
    // Opening a post whose newest reply is an answer shows that thread.
    if (_seenReplies == 0 && all.isNotEmpty && all.last.parentId != null) _expanded.add(all.last.parentId!);
    if (_answering != null && !all.any((r) => r.id == _answering!.id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _answering = null);
      });
    }
    final count = all.length;
    if (count > _seenReplies && _seenReplies > 0 && _nearBottom) _scrollToEnd();
    _seenReplies = count;
  }

  bool get _nearBottom => !_scroll.hasClients || _scroll.position.extentAfter < 160;

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final answering = _answering;
    final reply = await _thread.send(_composer.text, parentId: answering?.id, photo: _photo);
    if (reply == null || !mounted) return;
    _composer.clear();
    setState(() {
      _photo = null;
      _answering = null;
    });
    _seenReplies = _thread.replies.length;
    if (answering == null) _scrollToEnd();
  }

  /// Answers [reply]. An answer to an answer goes under the same top-level
  /// reply and starts with "@name".
  void _answer(Reply reply) {
    final top = reply.parentId == null
        ? reply
        : _thread.replies.firstWhere((r) => r.id == reply.parentId, orElse: () => reply);
    setState(() {
      _answering = top;
      _expanded.add(top.id);
    });
    if (reply.parentId != null && !_people.isMine(reply.authorId)) {
      final mention = '@${_people.nameOf(reply.authorId)} ';
      if (!_composer.text.startsWith(mention)) {
        _composer.value = TextEditingValue(
          text: '$mention${_composer.text}',
          selection: TextSelection.collapsed(offset: mention.length + _composer.text.length),
        );
      }
    }
    _replyFocus.requestFocus();
  }

  Future<void> _pickPhoto() async {
    try {
      final picked = await _deps.photoPicker.pick(PhotoSource.gallery, limit: 1);
      if (picked.isNotEmpty && mounted) setState(() => _photo = picked.first);
    } on AppFailure catch (f) {
      _notice(f);
    }
  }

  Future<void> _edit(Note note) async {
    await widget.onEdit(note);
    if (mounted) await _reload();
  }

  Future<void> _delete(Note note) async {
    final deleted = await widget.onDelete(note);
    if (deleted && mounted) Navigator.of(context).pop();
  }

  Future<void> _editReply(Reply reply) async {
    final text = await editReplyText(context, reply.body);
    if (text == null || !mounted) return;
    _notice(await _thread.editReply(reply, text));
  }

  Future<void> _deleteReply(Reply reply) async {
    if (!await confirmDeleteReply(context) || !mounted) return;
    _notice(await _thread.deleteReply(reply));
  }

  Future<void> _togglePin(Note note) async {
    final pinned = !(_people.byId(note.id)?.pinned ?? note.pinned);
    _notice(await _people.togglePin(_people.byId(note.id) ?? note));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(pinned ? 'Pinned to your profile' : 'Unpinned')));
  }

  Future<void> _likeReply(Reply reply) async {
    _notice(await _thread.toggleReplyLike(reply, _people.meId));
  }

  void _notice(AppFailure? failure) {
    if (failure == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failure.message)));
  }

  Future<void> _like() async {
    final failure = await _thread.toggleLike(_people.meId);
    if (failure == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failure.message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post'),
        shape: Border(bottom: BorderSide(color: context.hairline, width: 0.6)),
        actions: [
          ListenableBuilder(
            listenable: Listenable.merge([_thread, _people]),
            builder: (context, _) {
              final note = _thread.note;
              if (note == null || note.isDraft) return const SizedBox.shrink();
              final pinned = _people.byId(note.id)?.pinned ?? note.pinned;
              return IconButton(
                key: const Key('pin-button'),
                tooltip: pinned ? 'Unpin' : 'Pin to your profile',
                isSelected: pinned,
                onPressed: () => _togglePin(note),
                icon: const Icon(Icons.push_pin_outlined),
                selectedIcon: const Icon(Icons.push_pin_rounded),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _thread,
        builder: (context, _) {
          final note = _thread.note;
          final failure = _thread.failure;
          if (note == null) {
            if (failure != null && !_thread.isLoading) {
              return CenteredMessage(message: failure.message, actionLabel: 'Try again', onAction: _thread.load);
            }
            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          }
          final mine = _people.isMine(note.authorId);
          return Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _reload(userInitiated: true),
                  child: ListView(
                    key: const Key('post-thread'),
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      ReadableWidth(
                        child: PostView(
                          note: note,
                          authorName: _people.nameOf(note.authorId),
                          photos: _thread.photos,
                          loadPhoto: _deps.photosRepository.loadPhoto,
                          loadPreview: _deps.photosRepository.loadPreview,
                          full: true,
                          seen: _people.isSeenByOther(note),
                          liked: note.isLikedBy(_people.meId),
                          onLike: note.isDraft ? null : _like,
                          onReply: note.isDraft ? null : _replyFocus.requestFocus,
                          onEdit: mine ? () => _edit(note) : null,
                          onDelete: mine ? () => _delete(note) : null,
                        ),
                      ),
                      ReadableWidth(child: _repliesHeader()),
                      for (final reply in _thread.topLevel) ...[
                        ReadableWidth(child: _replyTile(reply)),
                        ..._answers(reply),
                      ],
                    ],
                  ),
                ),
              ),
              if (note.isDraft)
                _DraftNotice(isMine: mine)
              else
                ReplyComposer(
                  controller: _composer,
                  focusNode: _replyFocus,
                  isSending: _thread.isSending,
                  failure: _thread.sendFailure,
                  myName: _people.me?.displayName ?? '',
                  recipientName: mine ? (_people.other?.displayName ?? '') : _people.nameOf(note.authorId),
                  onSend: _send,
                  photo: _photo,
                  onPickPhoto: _pickPhoto,
                  onRemovePhoto: () => setState(() => _photo = null),
                  answeringName: _answering == null ? null : _people.nameOf(_answering!.authorId),
                  onStopAnswering: () => setState(() => _answering = null),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _replyTile(Reply reply) {
    final mine = _people.isMine(reply.authorId);
    return ReplyTile(
      reply: reply,
      authorName: _people.nameOf(reply.authorId),
      isMine: mine,
      isAnswer: reply.parentId != null,
      loadPhoto: _deps.repliesRepository.loadPhoto,
      liked: reply.isLikedBy(_people.meId),
      onLike: () => _likeReply(reply),
      onReply: () => _answer(reply),
      onEdit: mine ? () => _editReply(reply) : null,
      onDelete: mine ? () => _deleteReply(reply) : null,
    );
  }

  /// The answers under [top]: hidden behind "View n replies" until opened.
  List<Widget> _answers(Reply top) {
    final answers = _thread.answersTo(top.id);
    if (answers.isEmpty) return const [];
    final open = _expanded.contains(top.id);
    return [
      if (open)
        for (final answer in answers) ReadableWidth(child: _replyTile(answer)),
      ReadableWidth(
        child: _AnswersToggle(
          key: ValueKey('view-answers-${top.id}'),
          count: answers.length,
          open: open,
          onTap: () => setState(() => open ? _expanded.remove(top.id) : _expanded.add(top.id)),
        ),
      ),
    ];
  }

  Widget _repliesHeader() {
    final count = _thread.replies.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: context.hairline, width: 0.6),
          bottom: BorderSide(color: context.hairline, width: 0.6),
        ),
      ),
      child: Text(
        count == 0
            ? 'No replies yet'
            : count == 1
            ? '1 reply'
            : '$count replies',
        key: const Key('replies-header'),
        style: context.text.titleSmall,
      ),
    );
  }
}

/// "View 3 replies" / "Hide replies" under a reply with answers.
class _AnswersToggle extends StatelessWidget {
  const _AnswersToggle({super.key, required this.count, required this.open, required this.onTap});

  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(52, 0, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: context.colors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 36),
            textStyle: context.text.labelLarge,
          ),
          icon: Icon(open ? Icons.expand_less : Icons.expand_more, size: 20),
          label: Text(
            open
                ? 'Hide replies'
                : count == 1
                ? 'View 1 reply'
                : 'View $count replies',
          ),
        ),
      ),
    );
  }
}

class _DraftNotice extends StatelessWidget {
  const _DraftNotice({required this.isMine});

  final bool isMine;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.hairline, width: 0.6)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: SafeArea(
        top: false,
        child: Text(
          isMine ? 'This is a draft only you can see. Post it to start a conversation.' : 'This is a draft.',
          textAlign: TextAlign.center,
          style: context.text.bodyMedium?.copyWith(color: context.muted),
        ),
      ),
    );
  }
}
