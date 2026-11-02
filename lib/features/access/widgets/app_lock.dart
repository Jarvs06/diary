import 'package:flutter/material.dart';

import '../../../core/app_dependencies.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ornaments.dart';
import 'gentle_message.dart';
import 'passcode_field.dart';

/// Covers the app until the phone's own lock (fingerprint, face, PIN or
/// pattern) is passed: when the app starts signed in, and when it comes back
/// after being away for [lockAfter]. Phones without a screen lock aren't
/// locked (there's nothing to unlock with). On the web it asks for your app
/// passcode instead.
class AppLock extends StatefulWidget {
  const AppLock({
    super.key,
    required this.dependencies,
    required this.child,
    this.lockAfter = const Duration(minutes: 2),
  });

  final AppDependencies dependencies;
  final Widget child;
  final Duration lockAfter;

  @override
  State<AppLock> createState() => _AppLockState();
}

class _AppLockState extends State<AppLock> with WidgetsBindingObserver {
  bool _available = false;
  bool _locked = false;
  bool _prompting = false;
  DateTime? _leftAt;

  bool get _signedIn => widget.dependencies.authSession.userId != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _start() async {
    _available = await widget.dependencies.screenLock.isAvailable();
    if (_available && _signedIn && mounted) {
      setState(() => _locked = true);
      await _unlock();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        // The unlock prompt itself can pause the app; that's not leaving.
        if (!_prompting) _leftAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final leftAt = _leftAt;
        _leftAt = null;
        if (leftAt != null &&
            DateTime.now().difference(leftAt) >= widget.lockAfter &&
            _available &&
            _signedIn &&
            !_locked) {
          setState(() => _locked = true);
          _unlock();
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _unlock() async {
    // The web lock waits for the passcode to be typed instead.
    if (_prompting || widget.dependencies.screenLock.usesPasscode) return;
    _prompting = true;
    final ok = await widget.dependencies.screenLock.unlock();
    _prompting = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_locked)
          Positioned.fill(
            // The cover sits above the app's Navigator, so it brings its own
            // Overlay for the text field (cursor, tooltips).
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => widget.dependencies.screenLock.usesPasscode
                      ? _PasscodeCover(
                          check: widget.dependencies.screenLock.unlockWithPasscode,
                          onUnlocked: () => setState(() => _locked = false),
                        )
                      : _LockCover(onUnlock: _unlock),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LockCover extends StatelessWidget {
  const _LockCover({required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('app-lock'),
      color: context.colors.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BrandTitle(size: 34),
                const SizedBox(height: 28),
                Icon(Icons.lock_outline, color: context.muted),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('unlock-button'),
                    onPressed: onUnlock,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: const Text('Unlock'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The web version's lock: your app passcode, checked by the server.
class _PasscodeCover extends StatefulWidget {
  const _PasscodeCover({required this.check, required this.onUnlocked});

  final Future<AppFailure?> Function(String passcode) check;
  final VoidCallback onUnlocked;

  @override
  State<_PasscodeCover> createState() => _PasscodeCoverState();
}

class _PasscodeCoverState extends State<_PasscodeCover> {
  final _passcode = TextEditingController();
  bool _checking = false;
  AppFailure? _failure;

  @override
  void dispose() {
    _passcode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_checking || _passcode.text.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _checking = true;
      _failure = null;
    });
    final failure = await widget.check(_passcode.text);
    if (!mounted) return;
    if (failure == null) {
      widget.onUnlocked();
      return;
    }
    _passcode.clear();
    setState(() {
      _checking = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    return Material(
      key: const Key('app-lock'),
      color: context.colors.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ReadableWidth(
              maxWidth: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: BrandTitle(size: 34)),
                  const SizedBox(height: 12),
                  Text(
                    'Enter your passcode to continue',
                    textAlign: TextAlign.center,
                    style: context.text.bodyMedium?.copyWith(color: context.muted),
                  ),
                  const SizedBox(height: 28),
                  PasscodeField(
                    controller: _passcode,
                    enabled: !_checking,
                    hasError: failure is IncorrectPasscode,
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) {
                      if (_failure != null) setState(() => _failure = null);
                    },
                  ),
                  if (failure != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                      child: GentleMessage(
                        message: failure.message,
                        icon: failure is TooManyAttempts ? Icons.hourglass_empty : Icons.info_outline,
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('unlock-button'),
                    onPressed: _checking ? null : _submit,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: _checking
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: context.colors.onPrimary),
                          )
                        : const Text('Unlock'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
