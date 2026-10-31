import '../../../core/auth/auth_session.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/network/backend_client.dart';
import '../models/welcome_content.dart';

abstract interface class AccessRepository {
  Future<WelcomeContent> fetchWelcome();

  /// Signs in whoever owns [passcode] and returns their participant id.
  /// Throws an [AppFailure] otherwise.
  Future<String> signIn(String passcode);
}

class SupabaseAccessRepository implements AccessRepository {
  SupabaseAccessRepository(this._backend, this._auth, {required this.appKey});

  final BackendClient _backend;
  final AuthSession _auth;
  final String appKey;

  @override
  Future<WelcomeContent> fetchWelcome() async {
    try {
      final data = await _backend.rpc('get_welcome', params: {'p_app_key': appKey});
      if (data is! Map<String, dynamic>) throw const UnexpectedFailure();
      return WelcomeContent.fromJson(data);
    } catch (e) {
      throw failureFromBackend(e);
    }
  }

  @override
  Future<String> signIn(String passcode) async {
    final Map<String, dynamic> data;
    try {
      data = await _backend.invokeFunction('sign-in', body: {'passcode': passcode});
    } catch (e) {
      throw failureFromBackend(e);
    }

    final refreshToken = data['refresh_token'];
    final participantId = data['participant_id'];
    if (refreshToken is! String || participantId is! String) {
      throw const UnexpectedFailure();
    }
    try {
      await _auth.establish(refreshToken: refreshToken);
    } catch (e) {
      throw failureFromData(e);
    }
    return participantId;
  }
}
