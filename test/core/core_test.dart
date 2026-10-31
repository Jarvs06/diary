import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secret_diary/core/config/app_config.dart';
import 'package:secret_diary/core/errors/app_failure.dart';
import 'package:secret_diary/core/network/backend_client.dart';
import 'package:secret_diary/core/utils/dates.dart';
import 'package:secret_diary/core/utils/ids.dart';
import 'package:secret_diary/features/notes/models/note.dart';
import 'package:secret_diary/features/photos/models/photo.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';

String _fakeJwt(Map<String, Object> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part(claims)}.signature';
}

void main() {
  group('AppConfig', () {
    AppConfig validate(String url, String key) =>
        AppConfig.validate(url: url, publishableKey: key, appKey: 'janina_letter');

    test('accepts a project URL and publishable key', () {
      expect(validate('https://abc.supabase.co', 'sb_publishable_xyz').supabaseUrl,
          'https://abc.supabase.co');
    });

    test('rejects missing values', () {
      expect(() => validate('', 'k'), throwsA(isA<ConfigException>()));
      expect(() => validate('https://abc.supabase.co', ''), throwsA(isA<ConfigException>()));
    });

    test('refuses secret and service_role keys', () {
      expect(() => validate('https://a.supabase.co', 'sb_secret_abc'),
          throwsA(isA<ConfigException>()));
      expect(() => validate('https://a.supabase.co', _fakeJwt({'role': 'service_role'})),
          throwsA(isA<ConfigException>()));
      expect(() => validate('https://a.supabase.co', _fakeJwt({'role': 'anon'})), returnsNormally);
    });
  });

  group('failureFromData', () {
    PostgrestException pg(String code) => PostgrestException(message: 'x', code: code);

    test('maps RLS refusals, expired sessions, missing rows and bad content', () {
      expect(failureFromData(pg('42501')), isA<NotAllowed>());
      expect(failureFromData(pg('PGRST301')), isA<SessionExpired>());
      expect(failureFromData(pg('PGRST116')), isA<NoteNotFound>());
      expect(failureFromData(pg('23514')), isA<InvalidContent>());
      expect(failureFromData(pg('XX000')), isA<ServiceUnavailable>());
    });

    test('maps network problems to NoConnection', () {
      expect(failureFromData(const SocketException('offline')), isA<NoConnection>());
      expect(failureFromData(const BackendUnreachable()), isA<NoConnection>());
    });

    test('passes AppFailures through unchanged', () {
      const f = EditConflict('latest');
      expect(failureFromData(f), same(f));
    });
  });

  group('Dates', () {
    final now = DateTime(2026, 10, 29, 15, 0);

    test('relative times for the sidebar', () {
      expect(Dates.relative(now.subtract(const Duration(seconds: 20)), now: now), 'now');
      expect(Dates.relative(now.subtract(const Duration(minutes: 5)), now: now), '5m');
      expect(Dates.relative(now.subtract(const Duration(hours: 3)), now: now), '3h');
      expect(Dates.relative(DateTime(2026, 10, 28, 20), now: now), 'Yesterday');
      expect(Dates.relative(DateTime(2026, 10, 1), now: now), 'Oct 1');
      expect(Dates.relative(DateTime(2025, 10, 1), now: now), 'Oct 1, 2025');
    });

    test('reply stamps', () {
      expect(Dates.stamp(DateTime(2026, 10, 29, 9, 5), now: now), '9:05 AM');
      expect(Dates.stamp(DateTime(2026, 10, 28, 21, 30), now: now), 'Yesterday, 9:30 PM');
      expect(Dates.stamp(DateTime(2026, 10, 2, 12, 0), now: now), 'Oct 2, 12:00 PM');
    });
  });

  test('diary dates', () {
    final d = DateTime(2026, 10, 31);
    expect(Dates.weekday(d), 'Saturday');
    expect(Dates.longDay(d), 'October 31, 2026');
    expect(Dates.iso(DateTime(2026, 3, 5)), '2026-03-05');
    expect(Dates.parseIso('2026-03-05'), DateTime(2026, 3, 5));
    expect(Dates.parseIso('nope'), isNull);
  });

  test('photo formats are recognised from their bytes, not their names', () {
    expect(PickedPhoto.detectExtension(pngBytes), 'png');
    expect(PickedPhoto.detectExtension(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'jpg');
    expect(
        PickedPhoto.detectExtension(Uint8List.fromList('RIFF\x00\x00\x00\x00WEBP'.codeUnits)), 'webp');
    expect(PickedPhoto.detectExtension(Uint8List.fromList('GIF89a'.codeUnits)), isNull);
  });

  test('storage errors map to gentle failures', () {
    expect(failureFromData(const StorageException('x', statusCode: '403')), isA<NotAllowed>());
    expect(failureFromData(const StorageException('x', statusCode: '413')), isA<InvalidContent>());
    expect(failureFromData(const StorageException('x', statusCode: '500')), isA<ServiceUnavailable>());
  });

  test('newId produces distinct v4 UUIDs', () {
    final a = newId();
    expect(a, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(newId(), isNot(a));
  });

  group('Note', () {
    test('splits paragraphs on blank lines and keeps single line breaks', () {
      final n = note(body: 'One\nstill one\n\nTwo\r\n\r\n\n  \nThree');
      expect(n.paragraphs, ['One\nstill one', 'Two', 'Three']);
    });

    test('preview is the first non-empty line; blank titles show the day', () {
      final n = note(title: ' ', body: '\n\n  Dear Janina,  \nmore', entryDate: DateTime(2026, 10, 31));
      expect(n.preview, 'Dear Janina,');
      expect(n.hasTitle, isFalse);
      expect(n.displayTitle, 'October 31, 2026');
    });

    test('entry_date is read as a calendar day', () {
      final n = Note.fromJson({
        'id': 'x', 'author_id': 'a', 'title': '', 'body': '', 'status': 'draft',
        'entry_date': '2026-10-31', 'version': 1,
        'created_at': '2026-10-31T23:30:00Z', 'updated_at': '2026-10-31T23:30:00Z',
        'last_activity_at': '2026-10-31T23:30:00Z',
      });
      expect(n.entryDate, DateTime(2026, 10, 31));
    });
  });
}
