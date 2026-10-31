import 'package:flutter/material.dart';

import '../../../core/app_dependencies.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/ornaments.dart';

/// Covers the app until the phone's own lock (fingerprint, face, PIN or
/// pattern) is passed: when the app starts signed in, and when it comes back
/// after being away for [lockAfter]. Phones without a screen lock aren't
/// locked (there's nothing to unlock with).
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
    if (_prompting) return;
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
        if (_locked) Positioned.fill(child: _LockCover(onUnlock: _unlock)),
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
