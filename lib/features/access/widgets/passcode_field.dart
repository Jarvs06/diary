import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';

/// Obscured, digits-only passcode input with a visibility toggle. Suggestions, autocorrect
/// and personalised learning are off so the passcode isn't remembered by the
/// keyboard.
class PasscodeField extends StatefulWidget {
  const PasscodeField({
    super.key,
    required this.controller,
    required this.onSubmitted,
    this.onChanged,
    this.enabled = true,
    this.hasError = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool hasError;

  @override
  State<PasscodeField> createState() => _PasscodeFieldState();
}

class _PasscodeFieldState extends State<PasscodeField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final errorBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: context.colors.error),
    );

    return TextField(
      key: const Key('passcode-field'),
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textInputAction: TextInputAction.go,
      maxLength: 12,
      style: context.text.bodyLarge?.copyWith(fontSize: 17, letterSpacing: 2),
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        hintText: 'Passcode',
        counterText: '',
        enabledBorder: widget.hasError ? errorBorder : null,
        focusedBorder: widget.hasError ? errorBorder : null,
        suffixIcon: IconButton(
          tooltip: _obscured ? 'Show passcode' : 'Hide passcode',
          icon: Icon(
            _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: context.muted,
          ),
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}
