import 'package:flutter/material.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ornaments.dart';
import '../../photos/models/photo.dart';
import '../../photos/widgets/photo_widgets.dart';

/// The "Reply to …" bar pinned under an entry. The text is only cleared by
/// the caller after the server confirms the reply was saved.
class ReplyComposer extends StatelessWidget {
  const ReplyComposer({
    super.key,
    required this.controller,
    required this.onSend,
    required this.isSending,
    required this.myName,
    this.failure,
    this.recipientName = '',
    this.focusNode,
    this.photo,
    this.onPickPhoto,
    this.onRemovePhoto,
    this.answeringName,
    this.onStopAnswering,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback onSend;
  final bool isSending;
  final String myName;
  final AppFailure? failure;
  final String recipientName;

  /// The photo waiting to be sent with the reply.
  final PickedPhoto? photo;
  final VoidCallback? onPickPhoto;
  final VoidCallback? onRemovePhoto;

  /// Set while answering someone's reply ("Replying to Janina ✕").
  final String? answeringName;
  final VoidCallback? onStopAnswering;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(top: BorderSide(color: context.hairline, width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: ReadableWidth(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (failure != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        'Not sent. ${failure!.message}',
                        key: const Key('reply-send-failure'),
                        style: context.text.bodyMedium?.copyWith(color: context.colors.error),
                      ),
                    ),
                  ),
                if (answeringName != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 0, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Replying to $answeringName',
                            key: const Key('answering-label'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.bodyMedium?.copyWith(color: context.muted),
                          ),
                        ),
                        IconButton(
                          key: const Key('stop-answering-button'),
                          tooltip: 'Cancel',
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          onPressed: isSending ? null : onStopAnswering,
                          icon: Icon(Icons.close, color: context.muted),
                        ),
                      ],
                    ),
                  ),
                if (photo != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(40, 0, 0, 8),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            key: const Key('reply-photo-preview'),
                            width: 72,
                            height: 90,
                            child: LocalPhoto(bytes: photo!.bytes, cacheWidth: 240),
                          ),
                        ),
                        Positioned(
                          top: -8,
                          right: -8,
                          child: IconButton.filled(
                            key: const Key('remove-reply-photo-button'),
                            tooltip: 'Remove photo',
                            visualDensity: VisualDensity.compact,
                            iconSize: 14,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black87,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(26, 26),
                              fixedSize: const Size(26, 26),
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: isSending ? null : onRemovePhoto,
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ],
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Avatar(name: myName, size: 30),
                    ),
                    if (onPickPhoto != null)
                      IconButton(
                        key: const Key('reply-photo-button'),
                        tooltip: 'Add a photo',
                        onPressed: isSending || photo != null ? null : onPickPhoto,
                        icon: Icon(Icons.image_outlined, color: context.muted),
                      )
                    else
                      const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        key: const Key('reply-field'),
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 6,
                        maxLength: 20000,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        style: context.text.bodyLarge,
                        decoration: InputDecoration(
                          hintText: answeringName != null
                              ? 'Reply to $answeringName…'
                              : recipientName.isEmpty
                              ? 'Reply…'
                              : 'Reply to $recipientName…',
                          counterText: '',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    ValueListenableBuilder(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final canSend = !isSending && (value.text.trim().isNotEmpty || photo != null);
                        return IconButton.filled(
                          key: const Key('reply-send-button'),
                          tooltip: 'Post reply',
                          onPressed: canSend ? onSend : null,
                          style: IconButton.styleFrom(
                            backgroundColor: context.colors.primary,
                            foregroundColor: context.colors.onPrimary,
                            disabledBackgroundColor: context.colors.surfaceContainerHighest,
                            disabledForegroundColor: context.muted,
                          ),
                          icon: isSending
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: context.muted,
                                    semanticsLabel: 'Sending',
                                  ),
                                )
                              : const Icon(Icons.arrow_upward_rounded, size: 22),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
