import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secret_diary/core/errors/app_failure.dart';
import 'package:secret_diary/features/access/services/access_controller.dart';

import '../../support/fakes.dart';

void main() {
  late FakeAuthSession auth;
  late FakeAccessRepository repository;
  late AccessController controller;

  setUp(() {
    auth = FakeAuthSession();
    repository = FakeAccessRepository(auth);
    controller = AccessController(repository: repository);
  });

  tearDown(() => controller.dispose());

  test('an empty passcode is rejected without calling the server', () async {
    expect(await controller.submit('  '), isNull);
    expect(controller.failure, isA<IncorrectPasscode>());
    expect(repository.signInCalls, 0);
  });

  test('an incorrect passcode signs nobody in', () async {
    expect(await controller.submit('999999'), isNull);
    expect(controller.failure, isA<IncorrectPasscode>());
    expect(auth.userId, isNull);
  });

  test("each person's passcode signs in that person", () async {
    expect(await controller.submit('135790'), janinaId);
    expect(auth.userId, janinaId);
    expect(await controller.submit('111111'), meId);
  });

  test('a lockout disables submitting until the delay passes', () {
    fakeAsync((async) {
      repository.nextFailure = const TooManyAttempts(Duration(minutes: 5));
      controller.submit('123456');
      async.flushMicrotasks();
      expect(controller.canSubmit, isFalse);

      async.elapse(const Duration(minutes: 5, seconds: 1));
      expect(controller.canSubmit, isTrue);
    });
  });

  test('an initial notice (e.g. signed out) is shown', () {
    final c = AccessController(repository: repository, initialNotice: const SessionExpired());
    expect(c.failure, isA<SessionExpired>());
    c.dispose();
  });
}
