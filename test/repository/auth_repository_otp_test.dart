import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Records the OTP calls and fails with [error] when set.
class _FakeRemote implements SupabaseRemoteDataSource {
  AuthException? error;
  final List<String> sentTo = [];
  final List<(String, String)> verified = [];

  @override
  Future<void> sendEmailOtp(String email) async {
    sentTo.add(email);
    if (error != null) throw error!;
  }

  @override
  Future<AuthResponse> verifyEmailOtp({required String email, required String token}) async {
    verified.add((email, token));
    if (error != null) throw error!;
    return AuthResponse();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedLocal implements LocalDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeRemote remote;
  late AuthRepository repository;

  setUp(() {
    remote = _FakeRemote();
    repository = AuthRepository(remote, _UnusedLocal());
  });

  Future<AppException> sendFailing(AuthException error) async {
    remote.error = error;
    try {
      await repository.sendLoginCode('ana@uniandes.edu.co');
    } on AppException catch (e) {
      return e;
    }
    fail('expected an AppException');
  }

  test('sends the code and verifies it with the same email', () async {
    await repository.sendLoginCode('ana@uniandes.edu.co');
    await repository.verifyLoginCode(email: 'ana@uniandes.edu.co', code: '123456');

    expect(remote.sentTo, ['ana@uniandes.edu.co']);
    expect(remote.verified, [('ana@uniandes.edu.co', '123456')]);
  });

  test('a wrong or expired code (Supabase: otp_expired for both) asks for a new one', () async {
    remote.error = const AuthException('Token has expired or is invalid', statusCode: '403', code: 'otp_expired');

    await expectLater(
      repository.verifyLoginCode(email: 'ana@uniandes.edu.co', code: '000000'),
      throwsA(isA<AppException>().having((e) => e.message, 'message', contains('Pide uno nuevo'))),
    );
  });

  test('an email without an account (shouldCreateUser: false) says to sign up', () async {
    final error = await sendFailing(
      const AuthException('Signups not allowed for otp', statusCode: '422', code: 'otp_disabled'),
    );

    expect(error.message, contains('Regístrate'));
    expect(error.isRetryable, isFalse);
  });

  test('the email rate limit says to wait', () async {
    final error = await sendFailing(
      const AuthException('email rate limit exceeded', statusCode: '429', code: 'over_email_send_rate_limit'),
    );

    expect(error.message, contains('Espera'));
  });

  test('no connection is retryable', () async {
    final error = await sendFailing(AuthRetryableFetchException());

    expect(error.message, contains('Sin conexión'));
    expect(error.isRetryable, isTrue);
  });

  test('an unknown error code keeps Supabase\'s own message', () async {
    final error = await sendFailing(const AuthException('Something odd', code: 'unexpected_failure'));

    expect(error.message, 'Something odd');
  });
}
