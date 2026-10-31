import 'package:flutter_test/flutter_test.dart';
import 'package:secret_diary/core/errors/app_failure.dart';
import 'package:secret_diary/core/network/backend_client.dart';
import 'package:secret_diary/features/access/data/access_repository.dart';

import '../../support/fakes.dart';

void main() {
  late FakeBackendClient backend;
  late FakeAuthSession auth;
  late SupabaseAccessRepository repository;

  setUp(() {
    backend = FakeBackendClient();
    auth = FakeAuthSession();
    repository = SupabaseAccessRepository(backend, auth, appKey: 'janina_letter');
  });

  group('signIn', () {
    test('calls sign-in and establishes the returned session', () async {
      backend.response = {
        'access_token': 'a',
        'refresh_token': 'refresh-123',
        'expires_at': 1900000000,
        'participant_id': janinaId,
      };

      final id = await repository.signIn('135790');

      expect(id, janinaId);
      expect(backend.calls.single.name, 'sign-in');
      expect(backend.calls.single.body, {'passcode': '135790'});
      expect(auth.refreshTokens, ['refresh-123']);
    });

    test('maps an incorrect passcode, including attempts remaining', () async {
      backend.error = const BackendException(
        status: 401,
        code: 'invalid_passcode',
        details: {'error': 'invalid_passcode', 'attempts_remaining': 2},
      );
      await expectLater(
        repository.signIn('0000'),
        throwsA(isA<IncorrectPasscode>().having((f) => f.attemptsRemaining, 'remaining', 2)),
      );
      expect(auth.refreshTokens, isEmpty);
    });

    test('maps a lockout to TooManyAttempts with the retry delay', () async {
      backend.error = const BackendException(
        status: 429,
        code: 'too_many_attempts',
        details: {'error': 'too_many_attempts', 'retry_after_seconds': 300},
      );
      await expectLater(
        repository.signIn('0000'),
        throwsA(isA<TooManyAttempts>()
            .having((f) => f.retryAfter, 'retryAfter', const Duration(minutes: 5))),
      );
    });

    test('maps no connection, not-ready and server errors', () async {
      backend.error = const BackendUnreachable();
      await expectLater(repository.signIn('1'), throwsA(isA<NoConnection>()));
      backend.error = const BackendException(status: 503, code: 'not_ready');
      await expectLater(repository.signIn('1'), throwsA(isA<NotReady>()));
      backend.error = const BackendException(status: 404); // function not deployed
      await expectLater(repository.signIn('1'), throwsA(isA<ServiceUnavailable>()));
    });

    test('treats a malformed success response as unexpected', () async {
      backend.response = {'access_token': 'a'};
      await expectLater(repository.signIn('1'), throwsA(isA<UnexpectedFailure>()));
      expect(auth.refreshTokens, isEmpty);
    });
  });

  group('fetchWelcome', () {
    test('reads the welcome text via get_welcome', () async {
      backend.response = {
        'recipient_name': 'Janina',
        'welcome_title': 'Hi, Janina.',
        'welcome_message': 'Read this.',
      };
      final welcome = await repository.fetchWelcome();
      expect(welcome.title, 'Hi, Janina.');
      expect(backend.calls.single.body, {'p_app_key': 'janina_letter'});
    });

    test('derives a title from the name when the title is blank', () async {
      backend.response = {'recipient_name': 'Janina', 'welcome_title': ' ', 'welcome_message': ''};
      expect((await repository.fetchWelcome()).title, 'Hi, Janina.');
    });
  });
}
