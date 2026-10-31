import 'package:supabase_flutter/supabase_flutter.dart';

/// A version of the APK you've handed out (a row in `app_releases`).
class AppRelease {
  const AppRelease({required this.versionCode, required this.versionName, required this.apkUrl, this.notes = ''});

  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String notes;

  factory AppRelease.fromJson(Map<String, dynamic> json) => AppRelease(
        versionCode: json['version_code'] as int,
        versionName: json['version_name'] as String? ?? '',
        apkUrl: json['apk_url'] as String,
        notes: json['notes'] as String? ?? '',
      );
}

abstract interface class ReleasesRepository {
  /// The newest release, or null if there are none (or it can't be checked).
  Future<AppRelease?> latest();
}

class SupabaseReleasesRepository implements ReleasesRepository {
  SupabaseReleasesRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<AppRelease?> latest() async {
    try {
      final row = await _client
          .from('app_releases')
          .select('version_code, version_name, apk_url, notes')
          .order('version_code', ascending: false)
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 15));
      return row == null ? null : AppRelease.fromJson(row);
    } catch (_) {
      // Not worth bothering anyone about.
      return null;
    }
  }
}
