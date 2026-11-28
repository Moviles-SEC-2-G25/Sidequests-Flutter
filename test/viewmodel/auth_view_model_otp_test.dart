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
import 'package:sidequests/view/widgets/offline_notice.dart';
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
  AppException? verifyError;
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
    if (verifyError != null) throw verifyError!;
    if (code != _validCode) {
      throw const AppException('The code is incorrect or has expired. Request a new one.');
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
  late bool isOffline;
  late StreamController<bool> offlineChanges;

  setUp(() {
    repository = _FakeAuthRepository();
    isOffline = false;
    offlineChanges = StreamController<bool>.broadcast();
    viewModel = AuthViewModel(
      repository,
      _NoBiometrics(),
      _SilentTracker(),
      isOffline: () async => isOffline,
      offlineChanges: () => offlineChanges.stream,
    );
  });

  tearDown(() => offlineChanges.close());

  group('AuthViewModel without a connection', () {
    test('sending never calls Supabase and says why', () async {
      isOffline = true;

      final sent = await viewModel.sendLoginCode('ana@uniandes.edu.co');

      expect(sent, isFalse);
      expect(repository.sentTo, isEmpty);
      expect(viewModel.otpErrorMessage, 'Offline. Connect to receive your code.');
      expect(viewModel.otpFailedForConnection, isTrue);
      expect(viewModel.isSendingCode, isFalse);
    });

    test('verifying never calls Supabase, says why and stays signed out', () async {
      isOffline = true;

      final success = await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: _validCode);

      expect(success, isFalse);
      expect(repository.triedCodes, isEmpty);
      expect(viewModel.otpErrorMessage, 'Offline. Connect to verify your code.');
      expect(viewModel.otpFailedForConnection, isTrue);
      expect(viewModel.isVerifyingCode, isFalse);
      expect(viewModel.status, AuthStatus.unauthenticated);
      expect(viewModel.errorMessage, isNull);
    });

    test('"online" but the request fails: counts as connection, unlike a wrong code', () async {
      repository.verifyError = const AppException('Offline. Try again.', isRetryable: true);
      await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: _validCode);
      expect(repository.triedCodes, [_validCode]);
      expect(viewModel.otpFailedForConnection, isTrue);

      repository.verifyError = null;
      await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: '000000');
      expect(viewModel.otpFailedForConnection, isFalse);
    });

    test('a retryable send failure counts as connection; a rejected one does not', () async {
      repository.sendError = const AppException('Offline. Try again.', isRetryable: true);
      await viewModel.sendLoginCode('ana@uniandes.edu.co');
      expect(viewModel.otpFailedForConnection, isTrue);

      repository.sendError = const AppException('There is no account with that email. Sign up first.');
      await viewModel.sendLoginCode('ana@uniandes.edu.co');
      expect(viewModel.otpFailedForConnection, isFalse);
    });

    test('a second verify while the first runs does not try the code twice', () async {
      repository.verifyGate = Completer<void>();

      final first = viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: _validCode);
      final second = await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: _validCode);
      await pumpEventQueue();
      repository.verifyGate!.complete();
      await first;

      expect(second, isFalse);
      expect(repository.triedCodes, [_validCode]);
    });

    test('coming back online clears only a connection message', () async {
      isOffline = true;
      await viewModel.sendLoginCode('ana@uniandes.edu.co');
      viewModel.clearOtpConnectionError();
      expect(viewModel.otpErrorMessage, isNull);
      expect(viewModel.otpFailedForConnection, isFalse);

      isOffline = false;
      await viewModel.verifyLoginCode(email: 'ana@uniandes.edu.co', code: '000000');
      viewModel.clearOtpConnectionError();
      expect(viewModel.otpErrorMessage, contains('Request a new one'));
    });
  });

  group('AuthViewModel', () {
    test('sending the code does not touch the session status', () async {
      final sent = await viewModel.sendLoginCode('ana@uniandes.edu.co');

      expect(sent, isTrue);
      expect(viewModel.status, AuthStatus.unauthenticated);
      expect(viewModel.isSendingCode, isFalse);
    });

    test('a failed send shows its error on the code screen, not on LoginView', () async {
      repository.sendError = const AppException('There is no account with that email. Sign up first.');

      final sent = await viewModel.sendLoginCode('nadie@uniandes.edu.co');

      expect(sent, isFalse);
      expect(viewModel.otpErrorMessage, contains('Sign up'));
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
      expect(viewModel.otpErrorMessage, contains('Request a new one'));
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
                      child: const Text('Log in with a code'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Log in with a code'));
      await tester.pumpAndSettle();
    }

    Future<void> goToCodeStep(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), '  Ana@Uniandes.edu.co ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pump();
      await tester.pump();
    }

    FilledButton filledButton(WidgetTester tester, String label) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

    testWidgets('"Send code" stays disabled until the email looks valid', (tester) async {
      await pumpOtpScreen(tester);
      expect(filledButton(tester, 'Send code').onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'ana@');
      await tester.pump();
      expect(filledButton(tester, 'Send code').onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'ana@uniandes.edu.co');
      await tester.pump();
      expect(filledButton(tester, 'Send code').onPressed, isNotNull);
    });

    testWidgets('sending moves to the code step, with the email trimmed and lowercased', (tester) async {
      await pumpOtpScreen(tester);

      await goToCodeStep(tester);

      expect(repository.sentTo, ['ana@uniandes.edu.co']);
      expect(find.text('ana@uniandes.edu.co'), findsOneWidget);
      expect(find.text('Code'), findsOneWidget);
    });

    testWidgets('resend waits 60 s, counting down, then sends again', (tester) async {
      await pumpOtpScreen(tester);
      await goToCodeStep(tester);

      final resend = find.widgetWithText(TextButton, 'Resend code (1:00)');
      expect(tester.widget<TextButton>(resend).onPressed, isNull);

      await tester.pump(const Duration(seconds: 15));
      expect(find.text('Resend code (0:45)'), findsOneWidget);

      await tester.pump(const Duration(seconds: 45));
      final ready = find.widgetWithText(TextButton, 'Resend code');
      expect(tester.widget<TextButton>(ready).onPressed, isNotNull);

      await tester.tap(ready);
      await tester.pump();
      await tester.pump();
      expect(repository.sentTo, hasLength(2));
      expect(find.text('Resend code (1:00)'), findsOneWidget); // countdown restarts
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

      expect(find.textContaining('Request a new one'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
      expect(find.byType(OtpLoginView), findsOneWidget);
    });

    testWidgets('"Change email" goes back to the email step', (tester) async {
      await pumpOtpScreen(tester);
      await goToCodeStep(tester);

      await tester.tap(find.text('Change email'));
      await tester.pump();

      expect(find.widgetWithText(FilledButton, 'Send code'), findsOneWidget);
    });

    testWidgets('a send error is shown on the email step', (tester) async {
      repository.sendError = const AppException('There is no account with that email. Sign up first.');
      await pumpOtpScreen(tester);

      await goToCodeStep(tester);

      expect(find.textContaining('Sign up'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Send code'), findsOneWidget); // still on step 1
    });

    group('without a connection', () {
      TextEditingController field(WidgetTester tester) =>
          tester.widget<TextField>(find.byType(TextField)).controller!;

      Future<void> goOffline(WidgetTester tester) async {
        isOffline = true;
        offlineChanges.add(true);
        await tester.pump();
      }

      Future<void> goOnline(WidgetTester tester) async {
        isOffline = false;
        offlineChanges.add(false);
        await tester.pump(); // delivers the event; its setState schedules a frame
        await tester.pump(); // draws that frame
      }

      testWidgets('opening the screen offline already says so and blocks sending', (tester) async {
        isOffline = true;
        await pumpOtpScreen(tester);
        await tester.enterText(find.byType(TextField), 'ana@uniandes.edu.co');
        await tester.pump();

        expect(find.text('Offline. Connect to receive your code.'), findsOneWidget);
        // Before any tap, and like LoginView's: an OfflineNotice.
        expect(find.descendant(of: find.byType(OfflineNotice), matching: find.text(AuthViewModel.offlineSendMessage)), findsOneWidget);
        expect(filledButton(tester, 'Send code').onPressed, isNull);
      });

      testWidgets('email step: keeps the email and reconnecting sends nothing by itself', (tester) async {
        await pumpOtpScreen(tester);
        await tester.enterText(find.byType(TextField), 'ana@uniandes.edu.co');
        await tester.pump();

        await goOffline(tester);
        expect(filledButton(tester, 'Send code').onPressed, isNull);
        expect(field(tester).text, 'ana@uniandes.edu.co');

        await goOnline(tester);
        await tester.pump();
        expect(filledButton(tester, 'Send code').onPressed, isNotNull);
        expect(find.textContaining('Offline'), findsNothing);
        expect(field(tester).text, 'ana@uniandes.edu.co');
        expect(repository.sentTo, isEmpty);
      });

      testWidgets('losing the connection between the check and the tap: no send, no countdown', (tester) async {
        await pumpOtpScreen(tester);
        await tester.enterText(find.byType(TextField), 'ana@uniandes.edu.co');
        await tester.pump();
        isOffline = true; // the stream hasn't told the screen yet

        await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
        await tester.pump();
        await tester.pump();

        expect(repository.sentTo, isEmpty);
        expect(find.text('Offline. Connect to receive your code.'), findsOneWidget);
        expect(find.descendant(of: find.byType(OfflineNotice), matching: find.text(AuthViewModel.offlineSendMessage)), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Send code'), findsOneWidget); // still on step 1
        expect(field(tester).text, 'ana@uniandes.edu.co');
        expect(find.textContaining('Resend code ('), findsNothing);
      });

      testWidgets('a connection error from a real attempt goes away once back online', (tester) async {
        await pumpOtpScreen(tester);
        await goToCodeStep(tester);
        repository.verifyError = const AppException('Offline. Try again.', isRetryable: true);
        await tester.enterText(find.byType(TextField), _validCode);
        await tester.pump();
        await tester.pump();
        expect(find.text('Offline. Try again.'), findsOneWidget);

        await goOffline(tester);
        await goOnline(tester);

        expect(find.textContaining('Offline'), findsNothing);
        expect(field(tester).text, _validCode);
      });

      testWidgets('code step: the 6th digit waits, the code stays and reconnecting tries nothing', (tester) async {
        await pumpOtpScreen(tester);
        await goToCodeStep(tester);
        await goOffline(tester);

        await tester.enterText(find.byType(TextField), _validCode);
        await tester.pump();
        await tester.pump();

        expect(repository.triedCodes, isEmpty);
        expect(field(tester).text, _validCode);
        expect(find.text('Offline. Connect to verify your code.'), findsOneWidget);
        expect(find.descendant(of: find.byType(OfflineNotice), matching: find.text(AuthViewModel.offlineVerifyMessage)), findsOneWidget);
        expect(filledButton(tester, 'Log in').onPressed, isNull);

        await goOnline(tester);
        await tester.pump();
        expect(repository.triedCodes, isEmpty);
        expect(field(tester).text, _validCode);
        expect(find.textContaining('Offline'), findsNothing);

        await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
        await tester.pumpAndSettle();
        expect(repository.triedCodes, [_validCode]);
        expect(find.byType(OtpLoginView), findsNothing);
      });

      testWidgets('"online" but the request fails: the code stays, unlike a wrong one', (tester) async {
        await pumpOtpScreen(tester);
        await goToCodeStep(tester);
        repository.verifyError = const AppException('Offline. Try again.', isRetryable: true);

        await tester.enterText(find.byType(TextField), _validCode);
        await tester.pump();
        await tester.pump();

        expect(repository.triedCodes, [_validCode]);
        expect(field(tester).text, _validCode);
        expect(find.byType(OtpLoginView), findsOneWidget);
      });

      testWidgets('resend stays off offline, and an earlier countdown keeps running', (tester) async {
        await pumpOtpScreen(tester);
        await goToCodeStep(tester);
        await goOffline(tester);

        await tester.pump(const Duration(seconds: 15));
        expect(find.text('Resend code (0:45)'), findsOneWidget);

        await tester.pump(const Duration(seconds: 45));
        final resend = find.widgetWithText(TextButton, 'Resend code');
        expect(tester.widget<TextButton>(resend).onPressed, isNull);
        expect(repository.sentTo, hasLength(1));

        await goOnline(tester);
        expect(tester.widget<TextButton>(resend).onPressed, isNotNull);
        expect(repository.sentTo, hasLength(1));
      });

      testWidgets('leaving the screen stops listening to connectivity', (tester) async {
        await pumpOtpScreen(tester);
        expect(offlineChanges.hasListener, isTrue);

        Navigator.of(tester.element(find.byType(OtpLoginView))).pop();
        await tester.pumpAndSettle();

        expect(offlineChanges.hasListener, isFalse);
      });
    });
  });
}
