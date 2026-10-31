import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Who is signed in, and how to sign in or out. A thin seam over Supabase
/// Auth so screens and controllers can be tested with a fake.
abstract interface class AuthSession {
  /// The signed-in participant's id (their Supabase Auth user id), or null.
  String? get userId;

  /// Turns the refresh token returned by the sign-in function into a
  /// persisted Supabase session.
  Future<void> establish({required String refreshToken});

  Future<void> signOut();

  /// Fires when the session ends for any reason (Lock, revoked, expired).
  Stream<void> get onSignedOut;
}

class SupabaseAuthSession implements AuthSession {
  SupabaseAuthSession(this._auth);

  final GoTrueClient _auth;

  @override
  String? get userId => _auth.currentUser?.id;

  @override
  Future<void> establish({required String refreshToken}) async {
    await _auth.setSession(refreshToken);
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } on Exception {
      // Offline: the local session is still cleared by signOut().
    }
  }

  @override
  Stream<void> get onSignedOut => _auth.onAuthStateChange
      .where((state) => state.event == AuthChangeEvent.signedOut)
      .map((_) {});
}

/// Keeps the Supabase session in the Android Keystore-backed secure storage
/// instead of plain SharedPreferences.
class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage();

  static const _key = 'supabase_session';
  static const _storage = FlutterSecureStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async {
    try {
      return await _storage.containsKey(key: _key);
    } on Exception {
      return false;
    }
  }

  @override
  Future<String?> accessToken() async {
    try {
      return await _storage.read(key: _key);
    } on Exception {
      // Corrupted keystore entry (e.g. after a device restore): start over.
      await removePersistedSession();
      return null;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() async {
    try {
      await _storage.delete(key: _key);
    } on Exception {
      // Nothing more we can do.
    }
  }
}
