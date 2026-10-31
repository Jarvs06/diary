import 'package:flutter/material.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ornaments.dart';

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
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final VoidCallback onSend;
  final bool isSending;
  final String myName;
  final AppFailure? failure;
  final String recipientName;

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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Avatar(name: myName, size: 30),
                    ),
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
                          hintText: recipientName.isEmpty ? 'Reply…' : 'Reply to $recipientName…',
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
                        final canSend = !isSending && value.text.trim().isNotEmpty;
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
