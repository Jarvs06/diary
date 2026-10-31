import 'package:flutter/material.dart';

import '../../../core/app_dependencies.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ornaments.dart';
import '../../notes/screens/home_screen.dart';
import '../services/access_controller.dart';
import '../widgets/gentle_message.dart';
import '../widgets/passcode_field.dart';

class PasscodeScreen extends StatefulWidget {
  const PasscodeScreen({super.key, required this.dependencies, this.notice});

  final AppDependencies dependencies;

  /// Shown when arriving here after being signed out (e.g. session expired).
  final AppFailure? notice;

  @override
  State<PasscodeScreen> createState() => _PasscodeScreenState();
}

class _PasscodeScreenState extends State<PasscodeScreen> {
  late final AccessController _controller = AccessController(
    repository: widget.dependencies.accessRepository,
    initialNotice: widget.notice,
  );
  final _passcode = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _passcode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final participantId = await _controller.submit(_passcode.text);
    if (participantId == null || !mounted) return;
    _passcode.clear();
    Navigator.of(
      context,
    ).pushReplacement(FadeRoute(builder: (_) => HomeScreen(dependencies: widget.dependencies)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final failure = _controller.failure;
            // Threads-style: the wordmark and tagline up top, one field
            // and one button in the middle.
            return LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ReadableWidth(
                  maxWidth: 380,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: constraints.maxHeight * 0.16),
                      const Center(child: BrandTitle(size: 40)),
                      const SizedBox(height: 20),
                      Text(
                        'A safe space for your thoughts, memories, and untold stories. '
                        'Write freely, feel deeply, and let every page tell your story.',
                        key: const Key('login-tagline'),
                        textAlign: TextAlign.center,
                        style: context.text.bodyMedium?.copyWith(
                          color: context.muted,
                          fontSize: 15.5,
                          height: 1.5,
                        ),
                      ),
                      SizedBox(height: constraints.maxHeight * 0.07),
                      PasscodeField(
                        controller: _passcode,
                        enabled: !_controller.isSubmitting,
                        hasError: failure is IncorrectPasscode,
                        onSubmitted: (_) => _submit(),
                        onChanged: (_) => _controller.clearFailure(),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        child: failure == null
                            ? const SizedBox(height: 12)
                            : Padding(
                                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                                child: GentleMessage(
                                  key: const Key('access-message'),
                                  message: failure.message,
                                  icon: failure is TooManyAttempts
                                      ? Icons.hourglass_empty
                                      : Icons.info_outline,
                                ),
                              ),
                      ),
                      const SizedBox(height: 4),
                      FilledButton(
                        key: const Key('open-letter-button'),
                        onPressed: _controller.canSubmit ? _submit : null,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                        child: _controller.isSubmitting
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: context.colors.onPrimary,
                                  semanticsLabel: 'Checking passcode',
                                ),
                              )
                            : const Text('Login'),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
