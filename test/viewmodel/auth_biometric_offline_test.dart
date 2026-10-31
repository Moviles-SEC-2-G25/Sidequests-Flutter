import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/testing.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/biometric_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/view/auth/auth_gate.dart';
import 'package:sidequests/view/auth/biometric_lock_view.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _confirmation =
    'Sin conexión no podrás iniciar sesión con tu contraseña hasta reconectar. '
    '¿Salir de todos modos?';

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

AnalyticsTracker _tracker() => AnalyticsTracker(
  eventSink: _NullSink(),
  contextManager: ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery()),
  sessionId: 'unused',
);

class _FakeBiometrics implements BiometricService {
  bool succeeds;

  _FakeBiometrics({this.succeeds = true});

  @override
  Future<bool> authenticate(String reason) async => succeeds;

  @override
  Future<bool> isAvailable() async => true;
}

/// The device's sensor, under the real BiometricService.
class _FakeLocalAuth implements LocalAuthentication {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<bool>.value(true);
}

/// Session on the device, nothing else: any other call would be a network
/// call, so it's recorded and fails like one.
class _OfflineRemote implements SupabaseRemoteDataSource {
  final List<Symbol> networkCalls = [];

  @override
  final Session? currentSession = _session(expiresIn: const Duration(hours: 1));

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    networkCalls.add(invocation.memberName);
    throw const SocketException('offline');
  }
}

Session _session({required Duration expiresIn}) {
  String encode(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final expiry = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  return Session(
    accessToken: '${encode({'alg': 'HS256'})}.${encode({'exp': expiry, 'sub': 'user-1'})}.signature',
    refreshToken: 'refresh-token',
    tokenType: 'bearer',
    user: const User(
      id: 'user-1',
      appMetadata: {},
      userMetadata: {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
    ),
  );
}

/// Only what the lock screen and AuthGate use.
class _FakeAuthRepository implements AuthRepository {
  final _changes = StreamController<AuthState>.broadcast();
  bool authenticated = true;
  int signOuts = 0;

  @override
  bool get isAuthenticated => authenticated;

  @override
  bool get isBiometricEnabled => true;

  @override
  Stream<AuthState> get authStateChanges => _changes.stream;

  @override
  Future<void> signOut() async {
    signOuts++;
    authenticated = false;
    _changes.add(const AuthState(AuthChangeEvent.signedOut, null));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('with the real flag, session restored and no network', () {
    late Directory documents;
    late LocalDataSource local;

    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      documents = await Directory.systemTemp.createTemp('biometric_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => documents.path,
      );
      SharedPreferences.setMockInitialValues({'biometric_enabled': true});
      local = LocalDataSource();
      await local.init();
    });

    tearDown(() async {
      await Hive.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        null,
      );
      await documents.delete(recursive: true);
    });

    test('starts locked and unlock() opens it, without a single network call', () async {
      final remote = _OfflineRemote();
      final viewModel = AuthViewModel(
        AuthRepository(remote, local),
        BiometricService(auth: _FakeLocalAuth()),
        _tracker(),
      );

      expect(viewModel.status, AuthStatus.authenticated);
      expect(viewModel.isLocked, isTrue);

      expect(await viewModel.unlock(), isTrue);

      expect(viewModel.isLocked, isFalse);
      expect(viewModel.status, AuthStatus.authenticated);
      expect(remote.networkCalls, isEmpty);
    });

    test('a failed fingerprint stays locked and still signed in', () async {
      final viewModel = AuthViewModel(
        AuthRepository(_OfflineRemote(), local),
        _FakeBiometrics(succeeds: false),
        _tracker(),
      );

      expect(await viewModel.unlock(), isFalse);

      expect(viewModel.isLocked, isTrue);
      expect(viewModel.status, AuthStatus.authenticated);
    });

    test('the flag off means no lock', () async {
      await local.setBiometricEnabled(false);

      final viewModel = AuthViewModel(
        AuthRepository(_OfflineRemote(), local),
        _FakeBiometrics(),
        _tracker(),
      );

      expect(viewModel.isLocked, isFalse);
    });

    test("Perfil's switch turns on and off offline and the choice persists", () async {
      final remote = _OfflineRemote();
      final viewModel = AuthViewModel(AuthRepository(remote, local), _FakeBiometrics(), _tracker());

      await viewModel.disableBiometric();
      expect(viewModel.biometricEnabled, isFalse);
      expect(local.isBiometricEnabled(), isFalse);

      expect(await viewModel.enableBiometric(), isTrue);
      expect(viewModel.biometricEnabled, isTrue);
      expect(local.isBiometricEnabled(), isTrue);

      await viewModel.loadBiometricAvailability();
      expect(viewModel.isBiometricAvailable, isTrue);
      expect(remote.networkCalls, isEmpty);
    });

    test('turning it on still needs the fingerprint', () async {
      await local.setBiometricEnabled(false);
      final viewModel = AuthViewModel(
        AuthRepository(_OfflineRemote(), local),
        _FakeBiometrics(succeeds: false),
        _tracker(),
      );

      expect(await viewModel.enableBiometric(), isFalse);

      expect(local.isBiometricEnabled(), isFalse);
    });

    group('over the real Supabase client, every request failing', () {
      late SupabaseClient client;

      setUp(() {
        client = SupabaseClient(
          'https://example.supabase.co',
          'key',
          httpClient: MockClient((_) async => throw const SocketException('offline')),
        );
      });

      tearDown(() => client.dispose());

      AuthViewModel newViewModel(_FakeBiometrics biometrics) => AuthViewModel(
        AuthRepository(SupabaseRemoteDataSource(client), local),
        biometrics,
        _tracker(),
      );

      test('an expired session survives the failed refresh: locked, not sent to login', () async {
        final expired = _session(expiresIn: const Duration(hours: -1));
        expect(expired.isExpired, isTrue);
        await client.auth.setInitialSession(jsonEncode(expired.toJson()));
        final events = <AuthChangeEvent>[];
        final subscription = client.auth.onAuthStateChange.listen(
          (state) => events.add(state.event),
          onError: (Object _) {},
        );
        final viewModel = newViewModel(_FakeBiometrics());

        await expectLater(
          client.auth.recoverSession(jsonEncode(expired.toJson())),
          throwsA(isA<AuthRetryableFetchException>()),
        );
        await pumpEventQueue();
        await subscription.cancel();

        // The stream error reached AuthViewModel too: unhandled, it fails this test.
        expect(events, isNot(contains(AuthChangeEvent.signedOut)));
        expect(client.auth.currentSession, isNotNull);
        expect(viewModel.status, AuthStatus.authenticated);
        expect(viewModel.isLocked, isTrue);
        expect(await viewModel.unlock(), isTrue);
      }, timeout: const Timeout(Duration(minutes: 1)));

      test('signing out offline really signs out and clears the account', () async {
        await client.auth.setInitialSession(
          jsonEncode(_session(expiresIn: const Duration(hours: 1)).toJson()),
        );
        await local.cacheQuestCatalog([{'id': 'a'}]);
        final viewModel = newViewModel(_FakeBiometrics());
        expect(viewModel.isLocked, isTrue);

        await viewModel.signOut();
        await pumpEventQueue();

        expect(viewModel.status, AuthStatus.unauthenticated);
        expect(viewModel.isLocked, isFalse);
        expect(client.auth.currentSession, isNull);
        expect(local.isBiometricEnabled(), isFalse);
        expect(local.getQuestCatalog(), isEmpty);
      });
    });
  });

  group('lock screen', () {
    late _FakeAuthRepository repository;

    Future<void> pumpLockScreen(WidgetTester tester, Future<bool> Function() isOffline) async {
      final viewModel = AuthViewModel(
        repository,
        _FakeBiometrics(succeeds: false), // leaves the buttons enabled
        _tracker(),
        isOffline: isOffline,
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthViewModel>.value(
          value: viewModel,
          child: MaterialApp(
            home: Builder(
              builder: (context) => context.watch<AuthViewModel>().isLocked
                  ? const BiometricLockView()
                  : const Text('login'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() => repository = _FakeAuthRepository());

    testWidgets('AuthGate decides on the lock screen with no network involved', (tester) async {
      final viewModel = AuthViewModel(repository, _FakeBiometrics(succeeds: false), _tracker());
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthViewModel>.value(
          value: viewModel,
          child: const MaterialApp(home: AuthGate()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BiometricLockView), findsOneWidget);
    });

    testWidgets('online, "Usar contraseña" signs out right away, as before', (tester) async {
      await pumpLockScreen(tester, () async => false);

      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(repository.signOuts, 1);
      expect(find.text('login'), findsOneWidget);
    });

    testWidgets('offline, it asks first', (tester) async {
      await pumpLockScreen(tester, () async => true);

      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();

      expect(find.text(_confirmation), findsOneWidget);
      expect(repository.signOuts, 0);
    });

    testWidgets('offline, "Cancelar" keeps the session and the lock', (tester) async {
      await pumpLockScreen(tester, () async => true);
      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(repository.signOuts, 0);
      expect(find.byType(BiometricLockView), findsOneWidget);
    });

    testWidgets('offline, tapping outside the dialog counts as cancelling', (tester) async {
      await pumpLockScreen(tester, () async => true);
      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(repository.signOuts, 0);
      expect(find.byType(BiometricLockView), findsOneWidget);
    });

    testWidgets('offline, "Salir" signs out', (tester) async {
      await pumpLockScreen(tester, () async => true);
      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Salir'));
      await tester.pumpAndSettle();

      expect(repository.signOuts, 1);
      expect(find.text('login'), findsOneWidget);
    });

    testWidgets('unknown connectivity behaves like online', (tester) async {
      await pumpLockScreen(tester, () async => throw PlatformException(code: 'no-plugin'));

      await tester.tap(find.text('Usar contraseña'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(repository.signOuts, 1);
    });
  });
}
