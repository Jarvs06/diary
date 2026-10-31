import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/app_dependencies.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ornaments.dart';
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
    if (_focusReplyOnLoad && _thread.note != null && !_thread.note!.isDraft) {
      _focusReplyOnLoad = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _replyFocus.requestFocus();
      });
    }
    final count = _thread.replies.length;
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
    final reply = await _thread.send(_composer.text);
    if (reply == null || !mounted) return;
    _composer.clear();
    _seenReplies = _thread.replies.length;
    _scrollToEnd();
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
      ),
      body: ListenableBuilder(
        listenable: _thread,
        builder: (context, _) {
          final note = _thread.note;
          final failure = _thread.failure;
          if (note == null) {
            if (failure != null && !_thread.isLoading) {
              return CenteredMessage(
                message: failure.message,
                actionLabel: 'Try again',
                onAction: _thread.load,
              );
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
                          full: true,
                          liked: note.isLikedBy(_people.meId),
                          onLike: note.isDraft ? null : _like,
                          onReply: note.isDraft ? null : _replyFocus.requestFocus,
                          onEdit: mine ? () => _edit(note) : null,
                          onDelete: mine ? () => _delete(note) : null,
                        ),
                      ),
                      ReadableWidth(child: _repliesHeader()),
                      for (final reply in _thread.replies)
                        ReadableWidth(
                          child: ReplyTile(
                            reply: reply,
                            authorName: _people.nameOf(reply.authorId),
                            isMine: _people.isMine(reply.authorId),
                            onEdit: _people.isMine(reply.authorId) ? () => _editReply(reply) : null,
                            onDelete: _people.isMine(reply.authorId) ? () => _deleteReply(reply) : null,
                          ),
                        ),
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
                ),
            ],
          );
        },
      ),
    );
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
