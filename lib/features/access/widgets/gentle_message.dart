import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// A quiet inline message (errors and notices): small icon and text, no box.
class GentleMessage extends StatelessWidget {
  const GentleMessage({super.key, required this.message, this.icon = Icons.info_outline});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final color = context.colors.error;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: context.text.bodyMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
