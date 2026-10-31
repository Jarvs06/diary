import 'dart:convert';

/// Build-time configuration, supplied with
/// `flutter run --dart-define-from-file=.env`.
///
/// Only the project URL and the *publishable* key belong here. Both are public
/// by design; the diary is protected server-side, not by hiding these values.
class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.appKey,
  });

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String appKey;

  static const _url = String.fromEnvironment('SUPABASE_URL');
  static const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const _appKey = String.fromEnvironment(
    'APP_KEY',
    defaultValue: 'janina_letter',
  );

  /// Reads the compiled-in values. Throws [ConfigException] if anything is
  /// missing or unsafe.
  factory AppConfig.fromEnvironment() =>
      AppConfig.validate(url: _url, publishableKey: _key, appKey: _appKey);

  factory AppConfig.validate({
    required String url,
    required String publishableKey,
    required String appKey,
  }) {
    final uri = Uri.tryParse(url.trim());
    if (url.trim().isEmpty ||
        uri == null ||
        !uri.hasAuthority ||
        !(uri.scheme == 'https' || uri.scheme == 'http')) {
      throw const ConfigException('SUPABASE_URL is missing or invalid.');
    }
    final key = publishableKey.trim();
    if (key.isEmpty) {
      throw const ConfigException('SUPABASE_PUBLISHABLE_KEY is missing.');
    }
    if (_looksLikeSecretKey(key)) {
      throw const ConfigException(
        'SUPABASE_PUBLISHABLE_KEY is a secret/service_role key. '
        'Use the publishable (or legacy anon) key instead.',
      );
    }
    if (appKey.trim().isEmpty) {
      throw const ConfigException('APP_KEY is empty.');
    }
    return AppConfig(
      supabaseUrl: url.trim(),
      supabasePublishableKey: key,
      appKey: appKey.trim(),
    );
  }

  /// Refuses to ship a privileged key inside the APK, even by accident.
  static bool _looksLikeSecretKey(String key) {
    if (key.startsWith('sb_secret_')) return true;
    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payload);
      return claims is Map && claims['role'] == 'service_role';
    } on FormatException {
      return false;
    }
  }
}

class ConfigException implements Exception {
  const ConfigException(this.message);

  final String message;

  @override
  String toString() => 'ConfigException: $message';
}
