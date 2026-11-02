import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/ornaments.dart';
import '../../photos/models/photo.dart';
import '../../photos/widgets/photo_widgets.dart';
import '../models/note.dart';

/// One diary entry as a post: avatar, name and the entry's date, then the title, text,
/// photos, and the like / reply row. In the feed ([full] false) long text is
/// cut short with "See more"; on the entry's own page the whole text shows.
class PostView extends StatelessWidget {
  const PostView({
    super.key,
    required this.note,
    required this.authorName,
    required this.photos,
    required this.loadPhoto,
    this.loadPreview,
    required this.liked,
    this.full = false,
    this.isNew = false,
    this.onTap,
    this.onLike,
    this.onReply,
    this.onEdit,
    this.onDelete,
  });

  final Note note;
  final String authorName;
  final List<NotePhoto> photos;
  final PhotoLoader loadPhoto;

  /// Loads the lighter preview shown in the post; full photos open from it.
  final PhotoLoader? loadPreview;

  /// Whether the signed-in person has liked it.
  final bool liked;
  final bool full;

  /// Posted by the other person since you last opened the feed.
  final bool isNew;

  /// Opens the entry's page (also used by "See more").
  final VoidCallback? onTap;

  /// Null for drafts, which can't be liked.
  final VoidCallback? onLike;

  /// The speech-bubble button; null for drafts, which can't be replied to.
  final VoidCallback? onReply;

  /// Shown in the ··· menu; both null for the other person's entries.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// Feed text limits: shorter when photos follow.
  static const linesWithPhotos = 2;
  static const linesWithoutPhotos = 6;

  @override
  Widget build(BuildContext context) {
    final body = note.body.trim();
    // Text sits to the right of the avatar; photos span the full width so
    // they scroll edge to edge, starting in line with the text (Threads).
    const textInset = 16.0 + 36 + 12; // padding + avatar + gap
    final content = Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Avatar(name: authorName),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(context),
                      if (note.hasTitle) ...[
                        const SizedBox(height: 2),
                        Text(note.displayTitle, key: const Key('note-title'), style: context.text.titleSmall),
                      ],
                      if (body.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: full
                              ? SelectableText(
                                  body,
                                  key: const Key('note-body'),
                                  style: context.text.bodyLarge,
                                )
                              : _ClippedText(
                                  text: body,
                                  maxLines: photos.isEmpty ? linesWithoutPhotos : linesWithPhotos,
                                  style: context.text.bodyLarge!,
                                  onSeeMore: onTap,
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 10),
            PhotoCarousel(
              photos: photos,
              load: loadPreview ?? loadPhoto,
              loadFull: loadPhoto,
              height: full ? 280 : 240,
              padding: const EdgeInsets.only(left: textInset, right: 16),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(left: textInset, right: 8, top: 4),
            child: _actions(context),
          ),
        ],
      ),
    );

    if (onTap == null) return content;
    return Semantics(
      button: true,
      child: InkWell(key: ValueKey('post-${note.id}'), onTap: onTap, child: content),
    );
  }

  Widget _header(BuildContext context) {
    final muted = context.text.bodyMedium?.copyWith(color: context.muted);
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    authorName,
                    key: const Key('note-byline'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.titleSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Text(Dates.short(note.entryDate), key: const Key('note-date'), style: muted),
                if (isNew) ...[
                  const SizedBox(width: 8),
                  Container(
                    key: ValueKey('new-dot-${note.id}'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: context.colors.primary, shape: BoxShape.circle),
                  ),
                ],
                if (note.isDraft) ...[
                  Text('  ·  ', style: muted),
                  Text('Draft', style: muted),
                ] else if (full && note.wasEdited) ...[
                  Text('  ·  ', style: muted),
                  Text('Edited', style: muted),
                ],
              ],
            ),
          ),
          if (onEdit != null || onDelete != null)
            PopupMenuButton<String>(
              key: ValueKey('post-menu-${note.id}'),
              tooltip: 'More',
              onSelected: (choice) => choice == 'delete' ? onDelete?.call() : onEdit?.call(),
              itemBuilder: (context) => [
                if (onEdit != null)
                  const PopupMenuItem(
                    key: Key('edit-note-button'),
                    value: 'edit',
                    child: Row(
                      children: [Icon(Icons.edit_outlined, size: 20), SizedBox(width: 12), Text('Edit')],
                    ),
                  ),
                if (onDelete != null)
                  PopupMenuItem(
                    key: const Key('delete-note-button'),
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
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.more_horiz, color: context.muted, size: 20),
              ),
            ),
        ],
      ),
    );
  }

  /// Heart and reply count, Threads-style.
  Widget _actions(BuildContext context) {
    final countStyle = context.text.bodyMedium?.copyWith(color: context.muted);
    return Transform.translate(
      offset: const Offset(-8, 0), // line the heart up with the text
      child: Row(
        children: [
          InkResponse(
            key: ValueKey('like-${note.id}'),
            onTap: onLike == null
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    onLike!();
                  },
            radius: 22,
            child: Semantics(
              button: true,
              toggled: liked,
              label: liked ? 'Unlike' : 'Like',
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, animation) =>
                          ScaleTransition(scale: animation, child: child),
                      child: Icon(
                        liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        key: ValueKey(liked),
                        size: 21,
                        color: liked ? AppPalette.like : context.colors.onSurface,
                      ),
                    ),
                    if (note.likeCount > 0) ...[
                      const SizedBox(width: 5),
                      Text('${note.likeCount}', key: ValueKey('like-count-${note.id}'), style: countStyle),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkResponse(
            key: ValueKey('reply-${note.id}'),
            onTap: onReply,
            radius: 22,
            child: Semantics(
              button: onReply != null,
              label: 'Reply',
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded, size: 20, color: context.colors.onSurface),
                    if (note.replyCount > 0) ...[
                      const SizedBox(width: 5),
                      Text('${note.replyCount}', key: ValueKey('reply-count-${note.id}'), style: countStyle),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Delete post?" confirmation. Returns true only if the person confirmed.
Future<bool> confirmDelete(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete post?'),
      content: const Text(
        "This removes the post, its photos and its replies for both of you. It can't be undone.",
      ),
      actions: [
        TextButton(
          key: const Key('cancel-delete-button'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm-delete-button'),
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Text cut to [maxLines] with a "See more" link underneath, shown only when
/// the text really is longer than that at the current width.
class _ClippedText extends StatelessWidget {
  const _ClippedText({required this.text, required this.maxLines, required this.style, this.onSeeMore});

  final String text;
  final int maxLines;
  final TextStyle style;
  final VoidCallback? onSeeMore;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final clipped = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              key: const Key('note-body'),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
            if (clipped)
              GestureDetector(
                key: const Key('see-more'),
                onTap: onSeeMore,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 2),
                  child: Text(
                    'See more',
                    style: style.copyWith(color: context.muted, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
