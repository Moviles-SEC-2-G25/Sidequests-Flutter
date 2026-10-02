import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/biometric_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/view/auth/otp_login_view.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent, AuthState, User;

const _validCode = '123456';

class _NoLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
  }) async => null;
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker()
    : super(
        eventSink: _NullSink(),
        contextManager: ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery()),
        sessionId: 'unused',
      );
}

class _NoBiometrics implements BiometricService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Supabase Auth in memory: only [_validCode] signs in, and doing so
/// fires `signedIn` like verifyOTP does.
class _FakeAuthRepository implements AuthRepository {
  final _changes = StreamController<AuthState>.broadcast();
  bool authenticated = false;
  bool biometric = false;
  AppException? sendError;
  final List<String> sentTo = [];
  final List<String> triedCodes = [];
  Completer<void>? verifyGate;

  @override
  bool get isAuthenticated => authenticated;

  @override
  User? get currentUser => null;

  @override
  Stream<AuthState> get authStateChanges => _changes.stream;

  @override
  bool get isBiometricEnabled => biometric;

  @override
  Future<void> sendLoginCode(String email) async {
    sentTo.add(email);
    if (sendError != null) throw sendError!;
  }

  @override
  Future<void> verifyLoginCode({required String email, required String code}) async {
    triedCodes.add(code);
    await verifyGate?.future;
    if (code != _validCode) {
      throw const AppException('El código no es correcto o ya venció. Pide uno nuevo.');
    }
    authenticated = true;
    _changes.add(const AuthState(AuthChangeEvent.signedIn, null));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeAuthRepository repository;
  late AuthViewModel viewModel;

  setUp(() {
    repository = _FakeAuthRepository();
    viewModel = AuthViewModel(repository, _NoBiometrics(), _SilentTracker());
  });

  group('AuthViewModel', () {
    test('sending the code does not touch the session status', () async {
      final sent = await viewModel.sendLoginCode('ana@uniandes.edu.co');

      expect(sent, isTrue);
      expect(viewModel.status, AuthStatus.unauthenticated);
      expect(viewModel.isSendingCode, isFalse);
    });

    test('a failed send shows its error on the code screen, not on LoginView', () async {
      repository.sendError = const AppException('No hay una cuenta con ese correo. Regístrate primero.');

      final sent = await viewModel.sendLoginCode('nadie@uniandes.edu.co');

      expect(sent, isFalse);
      expect(viewModel.otpErrorMessage, contains('Regístrate'));
      expect(viewModel.errorMessage, isNull);
    });

    test('the right code signs in', () async {
      final success = await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: _validCode);
      await Future<void>.delayed(Duration.zero);

      expect(success, isTrue);
      expect(viewModel.status, AuthStatus.authenticated);
    });

    test('a wrong code: error on the code screen, still signed out', () async {
      final success = await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: '000000');

      expect(success, isFalse);
      expect(viewModel.status, AuthStatus.unauthenticated);
      expect(viewModel.otpErrorMessage, contains('Pide uno nuevo'));
      expect(viewModel.errorMessage, isNull);
    });

    test('signing in with a code never shows the biometric lock (only a restored session does)', () async {
      repository.biometric = true; // even if the flag were on
      viewModel = AuthViewModel(repository, _NoBiometrics(), _SilentTracker());

      await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: _validCode);

      expect(viewModel.status, AuthStatus.authenticated);
      expect(viewModel.isLocked, isFalse);
    });
  });

  group('OtpLoginView', () {
    /// LoginView stand-in as the first route (AuthGate's place), with the
    /// code screen pushed on top, as in the app.
    Future<void> pumpOtpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthViewModel>.value(
          value: viewModel,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    const Text('first route'),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const OtpLoginView()),
                      ),
                      child: const Text('Entrar con código'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Entrar con código'));
      await tester.pumpAndSettle();
    }

    Future<void> goToCodeStep(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), '  Ana@Uniandes.edu.co ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Enviar código'));
      await tester.pump();
      await tester.pump();
    }

    FilledButton filledButton(WidgetTester tester, String label) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

    testWidgets('"Enviar código" stays disabled until the email looks valid', (tester) async {
      await pumpOtpScreen(tester);
      expect(filledButton(tester, 'Enviar código').onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'ana@');
      await tester.pump();
      expect(filledButton(tester, 'Enviar código').onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'ana@uniandes.edu.co');
      await tester.pump();
      expect(filledButton(tester, 'Enviar código').onPressed, isNotNull);
    });

    testWidgets('sending moves to the code step, with the email trimmed and lowercased', (tester) async {
      await pumpOtpScreen(tester);

      await goToCodeStep(tester);

      expect(repository.sentTo, ['ana@uniandes.edu.co']);
      expect(find.text('ana@uniandes.edu.co'), findsOneWidget);
      expect(find.text('Código'), findsOneWidget);
    });

    testWidgets('resend waits 60 s, counting down, then sends again', (tester) async {
      await pumpOtpScreen(tester);
      await goToCodeStep(tester);

      final resend = find.widgetWithText(TextButton, 'Reenviar código (1:00)');
      expect(tester.widget<TextButton>(resend).onPressed, isNull);

      await tester.pump(const Duration(seconds: 15));
      expect(find.text('Reenviar código (0:45)'), findsOneWidget);

      await tester.pump(const Duration(seconds: 45));
      final ready = find.widgetWithText(TextButton, 'Reenviar código');
      expect(tester.widget<TextButton>(ready).onPressed, isNotNull);

      await tester.tap(ready);
      await tester.pump();
      await tester.pump();
      expect(repository.sentTo, hasLength(2));
      expect(find.text('Reenviar código (1:00)'), findsOneWidget); // countdown restarts
    });

    testWidgets('the code field only takes digits, up to 6', (tester) async {
      await pumpOtpScreen(tester);
      await goToCodeStep(tester);
      repository.verifyGate = Completer<void>(); // keep the auto-verify pending

      await tester.enterText(find.byType(TextField), '12ab34567');
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '123456');
      repository.verifyGate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('typing the 6th digit signs in and returns to the first route (AuthGate)', (tester) async {
      await pumpOtpScreen(tester);
      await goToCodeStep(tester);

      await tester.enterText(find.byType(TextField), _validCode);
      await tester.pumpAndSettle();

      expect(repository.triedCodes, [_validCode]);
      expect(viewModel.status, AuthStatus.authenticated);
      expect(find.byType(OtpLoginView), findsNothing);
      expect(find.text('first route'), findsOneWidget);
    });

    testWidgets('a wrong code shows the error, clears the field and stays on the screen', (tester) async {
      await pumpOtpScreen(tester);
      await goToCodeStep(tester);

      await tester.enterText(find.byType(TextField), '000000');
      await tester.pumpAndSettle();

      expect(find.textContaining('Pide uno nuevo'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(find.byType(OtpLoginView), findsOneWidget);
    });

    testWidgets('"Cambiar correo" goes back to the email step', (tester) async {
      await pumpOtpScreen(tester);
      await goToCodeStep(tester);

      await tester.tap(find.text('Cambiar correo'));
      await tester.pump();

      expect(find.widgetWithText(FilledButton, 'Enviar código'), findsOneWidget);
    });

    testWidgets('a send error is shown on the email step', (tester) async {
      repository.sendError = const AppException('No hay una cuenta con ese correo. Regístrate primero.');
      await pumpOtpScreen(tester);

      await goToCodeStep(tester);

      expect(find.textContaining('Regístrate'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Enviar código'), findsOneWidget); // still on step 1
    });
  });
}
