import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/errors/app_failure.dart';
import '../data/access_repository.dart';
import '../models/welcome_content.dart';

/// State for the passcode screen. The passcode itself is never stored here;
/// it is passed straight through to the server and forgotten.
class AccessController extends ChangeNotifier {
  AccessController({required AccessRepository repository, AppFailure? initialNotice})
      : _repository = repository,
        _failure = initialNotice;

  final AccessRepository _repository;

  WelcomeContent? _welcome;
  bool _submitting = false;
  AppFailure? _failure;
  Timer? _lockTimer;
  bool _lockedOut = false;
  bool _disposed = false;

  /// Null while loading; [WelcomeContent.fallback] if loading failed.
  WelcomeContent? get welcome => _welcome;
  bool get isSubmitting => _submitting;
  AppFailure? get failure => _failure;
  bool get isLockedOut => _lockedOut;
  bool get canSubmit => !_submitting && !_lockedOut;

  Future<void> loadWelcome() async {
    try {
      _welcome = await _repository.fetchWelcome();
    } on AppFailure {
      _welcome = WelcomeContent.fallback;
    }
    _notify();
  }

  /// Returns the signed-in participant's id when the passcode is correct,
  /// otherwise null (with [failure] describing why).
  Future<String?> submit(String passcode) async {
    if (!canSubmit) return null;
    if (passcode.trim().isEmpty) {
      _failure = const IncorrectPasscode();
      _notify();
      return null;
    }

    _submitting = true;
    _failure = null;
    _notify();

    try {
      return await _repository.signIn(passcode);
    } on AppFailure catch (failure) {
      _failure = failure;
      if (failure is TooManyAttempts) _startLockout(failure.retryAfter);
      return null;
    } finally {
      _submitting = false;
      _notify();
    }
  }

  void clearFailure() {
    if (_failure == null || _lockedOut) return;
    _failure = null;
    _notify();
  }

  void _startLockout(Duration duration) {
    _lockTimer?.cancel();
    _lockedOut = true;
    _lockTimer = Timer(duration, () {
      _lockedOut = false;
      _failure = null;
      _notify();
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lockTimer?.cancel();
    super.dispose();
  }
}
