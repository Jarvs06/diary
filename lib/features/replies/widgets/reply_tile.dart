import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/ornaments.dart';
import '../../photos/widgets/photo_widgets.dart';
import '../models/reply.dart';

/// One reply under an entry, laid out like a Threads reply. An answer to
/// another reply ([isAnswer]) is indented under it with a smaller picture.
class ReplyTile extends StatelessWidget {
  const ReplyTile({
    super.key,
    required this.reply,
    required this.authorName,
    required this.isMine,
    required this.loadPhoto,
    this.isAnswer = false,
    this.liked = false,
    this.onLike,
    this.onReply,
    this.onEdit,
    this.onDelete,
  });

  final Reply reply;
  final String authorName;
  final bool isMine;
  final PhotoLoader loadPhoto;
  final bool isAnswer;

  /// Whether the signed-in person liked it, and the heart under the text.
  final bool liked;
  final VoidCallback? onLike;

  /// The "Reply" button under the text.
  final VoidCallback? onReply;

  /// Shown in the ··· menu on your own replies.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${isMine ? 'You' : authorName}, ${Dates.stamp(reply.createdAt)}',
      child: Padding(
        key: ValueKey('reply-${reply.id}'),
        padding: EdgeInsets.fromLTRB(isAnswer ? 60 : 16, isAnswer ? 8 : 12, 16, isAnswer ? 4 : 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Avatar(name: authorName, size: isAnswer ? 24 : 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          authorName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.titleSmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        reply.editedAt == null
                            ? Dates.relative(reply.createdAt)
                            : '${Dates.relative(reply.createdAt)}  ·  Edited',
                        style: context.text.bodyMedium?.copyWith(color: context.muted),
                      ),
                      const Spacer(),
                      if (onEdit != null || onDelete != null) _menu(context),
                    ],
                  ),
                  if (reply.body.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    SelectableText(reply.body, style: context.text.bodyLarge),
                  ],
                  if (reply.imagePath case final path?) ...[
                    const SizedBox(height: 8),
                    _ReplyPhoto(path: path, load: loadPhoto),
                  ],
                  if (onLike != null || onReply != null)
                    Transform.translate(
                      offset: const Offset(-8, 0), // line the heart up with the text
                      child: Row(
                        children: [
                          if (onLike != null) _likeButton(context),
                          if (onReply != null)
                            TextButton(
                              key: ValueKey('reply-to-${reply.id}'),
                              onPressed: onReply,
                              style: TextButton.styleFrom(
                                foregroundColor: context.muted,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                textStyle: context.text.labelLarge,
                              ),
                              child: const Text('Reply'),
                            ),
                        ],
                      ),
                    )
                  else
                    const SizedBox(height: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _likeButton(BuildContext context) => InkResponse(
    key: ValueKey('like-reply-${reply.id}'),
    radius: 18,
    onTap: () {
      HapticFeedback.lightImpact();
      onLike!();
    },
    child: Semantics(
      button: true,
      toggled: liked,
      label: liked ? 'Unlike reply' : 'Like reply',
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              size: 17,
              color: liked ? AppPalette.like : context.muted,
            ),
            if (reply.likedBy.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                '${reply.likedBy.length}',
                key: ValueKey('reply-like-count-${reply.id}'),
                style: context.text.bodyMedium?.copyWith(color: context.muted),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _menu(BuildContext context) => SizedBox(
    height: 24,
    child: PopupMenuButton<String>(
      key: ValueKey('reply-menu-${reply.id}'),
      tooltip: 'More',
      padding: EdgeInsets.zero,
      onSelected: (choice) => choice == 'delete' ? onDelete?.call() : onEdit?.call(),
      itemBuilder: (context) => [
        if (onEdit != null)
          const PopupMenuItem(
            key: Key('edit-reply-button'),
            value: 'edit',
            child: Row(children: [Icon(Icons.edit_outlined, size: 20), SizedBox(width: 12), Text('Edit')]),
          ),
        if (onDelete != null)
          PopupMenuItem(
            key: const Key('delete-reply-button'),
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 20, color: context.colors.error),
                const SizedBox(width: 12),
                Text('Delete', style: TextStyle(color: context.colors.error)),
              ],
            ),
          ),
      ],
      child: Icon(Icons.more_horiz, color: context.muted, size: 20),
    ),
  );
}

/// A reply's photo: a rounded preview that opens full screen.
class _ReplyPhoto extends StatelessWidget {
  const _ReplyPhoto({required this.path, required this.load});

  final String path;
  final PhotoLoader load;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Photo',
      child: GestureDetector(
        key: ValueKey('reply-photo-$path'),
        onTap: () => PhotoViewerScreen.open(context, paths: [path], load: load),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 240),
            child: AspectRatio(
              aspectRatio: 4 / 5,
              child: ColoredBox(
                color: context.colors.surfaceContainerHighest,
                child: RemotePhoto(storagePath: path, load: load, cacheWidth: 600),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Edits a reply's text in a dialog. Returns the new text, or null if cancelled.
Future<String?> editReplyText(BuildContext context, String current) => showDialog<String>(
  context: context,
  builder: (_) => _EditReplyDialog(initial: current),
);

class _EditReplyDialog extends StatefulWidget {
  const _EditReplyDialog({required this.initial});

  final String initial;

  @override
  State<_EditReplyDialog> createState() => _EditReplyDialogState();
}

class _EditReplyDialogState extends State<_EditReplyDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit reply'),
      content: TextField(
        key: const Key('edit-reply-field'),
        controller: _text,
        autofocus: true,
        minLines: 1,
        maxLines: 6,
        textCapitalization: TextCapitalization.sentences,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          key: const Key('save-reply-button'),
          onPressed: () => Navigator.pop(context, _text.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// "Delete reply?" confirmation. Returns true only if confirmed.
Future<bool> confirmDeleteReply(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete reply?'),
      content: const Text('It will be removed for both of you.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(
          key: const Key('confirm-delete-reply-button'),
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
