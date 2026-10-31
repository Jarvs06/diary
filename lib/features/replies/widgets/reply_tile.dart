import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/ornaments.dart';
import '../models/reply.dart';

/// One reply under an entry, laid out like a Threads reply.
class ReplyTile extends StatelessWidget {
  const ReplyTile({
    super.key,
    required this.reply,
    required this.authorName,
    required this.isMine,
    this.onEdit,
    this.onDelete,
  });

  final Reply reply;
  final String authorName;
  final bool isMine;

  /// Shown in the ··· menu on your own replies.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${isMine ? 'You' : authorName}, ${Dates.stamp(reply.createdAt)}',
      child: Padding(
        key: ValueKey('reply-${reply.id}'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Avatar(name: authorName, size: 32),
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
                  const SizedBox(height: 2),
                  SelectableText(reply.body, style: context.text.bodyLarge),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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

/// Edits a reply's text in a dialog. Returns the new text, or null if cancelled.
Future<String?> editReplyText(BuildContext context, String current) =>
    showDialog<String>(context: context, builder: (_) => _EditReplyDialog(initial: current));

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
