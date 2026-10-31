import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../errors/app_failure.dart';
import 'socket_error_io.dart' if (dart.library.js_interop) 'socket_error_web.dart';

/// Thin seam over Supabase so repositories can be tested with a fake.
abstract interface class BackendClient {
  /// Calls an Edge Function and returns its decoded JSON object.
  Future<Map<String, dynamic>> invokeFunction(
    String name, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  });

  /// Calls a Postgres function exposed through the Data API.
  Future<Object?> rpc(String name, {Map<String, dynamic>? params});
}

/// A non-2xx response. [code] is the `error` field our functions return.
class BackendException implements Exception {
  const BackendException({required this.status, this.code, this.details = const {}});

  final int status;
  final String? code;
  final Map<String, dynamic> details;

  @override
  String toString() => 'BackendException($status, $code)';
}

/// The server could not be reached at all (offline, DNS, timeout).
class BackendUnreachable implements Exception {
  const BackendUnreachable();
}

class SupabaseBackendClient implements BackendClient {
  SupabaseBackendClient(
    this._client, {
    this.timeout = const Duration(seconds: 20),
  });

  final SupabaseClient _client;
  final Duration timeout;

  @override
  Future<Map<String, dynamic>> invokeFunction(
    String name, {
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _client.functions
          .invoke(name, body: body ?? const {}, headers: headers)
          .timeout(timeout);
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      throw BackendException(status: response.status);
    } on FunctionException catch (e) {
      final details = _asMap(e.details);
      throw BackendException(
        status: e.status,
        code: details['error'] as String?,
        details: details,
      );
    } on TimeoutException {
      throw const BackendUnreachable();
    } on http.ClientException {
      throw const BackendUnreachable();
    } catch (e) {
      if (isSocketError(e)) throw const BackendUnreachable();
      rethrow;
    }
  }

  @override
  Future<Object?> rpc(String name, {Map<String, dynamic>? params}) async {
    try {
      return await _client.rpc<Object?>(name, params: params).timeout(timeout);
    } on PostgrestException catch (e) {
      throw BackendException(status: int.tryParse(e.code ?? '') ?? 500);
    } on TimeoutException {
      throw const BackendUnreachable();
    } on http.ClientException {
      throw const BackendUnreachable();
    } catch (e) {
      if (isSocketError(e)) throw const BackendUnreachable();
      rethrow;
    }
  }

  static Map<String, dynamic> _asMap(Object? details) {
    if (details is Map<String, dynamic>) return details;
    if (details is String) {
      try {
        final decoded = jsonDecode(details);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        // Not JSON; fall through.
      }
    }
    return const {};
  }
}

/// Translates Edge Function / RPC errors into failures the UI can show.
AppFailure failureFromBackend(Object error) {
  if (error is AppFailure) return error;
  if (error is BackendUnreachable) return const NoConnection();
  if (error is! BackendException) return const UnexpectedFailure();

  final details = error.details;
  switch (error.code) {
    case 'invalid_passcode':
    case 'bad_request':
      return IncorrectPasscode(
        attemptsRemaining: (details['attempts_remaining'] as num?)?.toInt(),
      );
    case 'too_many_attempts':
      final seconds = (details['retry_after_seconds'] as num?)?.toInt() ?? 60;
      return TooManyAttempts(Duration(seconds: seconds));
    case 'not_ready':
      return const NotReady();
    default:
      // server_error, a function that isn't deployed, gateway errors, etc.
      return const ServiceUnavailable();
  }
}

/// Translates PostgREST / Auth / network errors from direct table access.
AppFailure failureFromData(Object error) {
  if (error is AppFailure) return error;
  if (error is TimeoutException ||
      isSocketError(error) ||
      error is http.ClientException ||
      error is BackendUnreachable) {
    return const NoConnection();
  }
  if (error is AuthException) {
    return error.statusCode == null ? const NoConnection() : const SessionExpired();
  }
  if (error is PostgrestException) {
    switch (error.code) {
      case '42501': // insufficient privilege / RLS violation
        return const NotAllowed();
      case 'PGRST301': // JWT expired
      case 'PGRST302':
      case 'PGRST303':
        return const SessionExpired();
      case 'PGRST116': // .single() found no row
        return const NoteNotFound();
      case '23514': // check constraint
        return const InvalidContent();
    }
    return const ServiceUnavailable();
  }
  if (error is StorageException) {
    switch (error.statusCode) {
      case '401':
        return const SessionExpired();
      case '403':
        return const NotAllowed();
      case '413':
        return const InvalidContent('That photo is too large.');
      case '415':
        return const InvalidContent("That photo's format isn't supported.");
    }
    return const ServiceUnavailable();
  }
  if (error is FormatException || error is TypeError) return const UnexpectedFailure();
  return const ServiceUnavailable();
}
