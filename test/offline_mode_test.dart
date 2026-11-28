import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/biometric_service.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/photo_capture_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/explore_filters.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/auth/login_view.dart';
import 'package:sidequests/view/profile/edit_preferences_view.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/view/quests/quest_detail_view.dart';
import 'package:sidequests/view/widgets/offline_notice.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The app in airplane mode: what works offline keeps working, and what needs
/// the internet is blocked before the user tries it, saying why.

const _userId = 'user-1';
const _none = [ConnectivityResult.none];
const _wifi = [ConnectivityResult.wifi];

const _quest = Quest(
  id: 'a',
  title: 'Quest a',
  category: 'food',
  durationMinutes: 20,
  difficulty: 'easy',
  locationMode: 'anywhere',
  socialLevel: 'solo',
);

final _mission = UserQuest(
  id: 'uq-a',
  userId: _userId,
  questId: 'a',
  status: 'in_progress',
  acceptedAt: DateTime(2026, 11, 1),
);

QuestStep _step(int order, [String verificationType = 'none']) => QuestStep(
  id: order,
  questId: 'a',
  stepOrder: order,
  title: 'Paso $order',
  verificationType: verificationType,
);

class _FakeConnectivity implements Connectivity {
  List<ConnectivityResult> current;
  final _changes = StreamController<List<ConnectivityResult>>.broadcast();

  _FakeConnectivity(this.current);

  void set(List<ConnectivityResult> results) {
    current = results;
    _changes.add(results);
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A platform without the connectivity API.
class _NoConnectivityApi implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => throw UnsupportedError('none');

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({LocationAccuracy accuracy = LocationAccuracy.medium}) async =>
      null;
}

/// A GPS that throws instead of answering (e.g. the location service went away).
class _BrokenLocation extends LocationService {
  @override
  Future<Position?> getCurrentPosition({LocationAccuracy accuracy = LocationAccuracy.medium}) async =>
      throw StateError('location service gone');
}

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _NoLostPhoto extends PhotoCaptureService {
  @override
  Future<Uint8List?> retrieveLost() async => null;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

ContextManager _contextManager({LocationService? location}) => ContextManager(
  locationService: location ?? _NoLocation(),
  batteryMonitor: _FullBattery(),
  connectivity: _FakeConnectivity(_wifi),
);

class _SilentTracker extends AnalyticsTracker {
  _SilentTracker()
    : super(eventSink: _NullSink(), contextManager: _contextManager(), sessionId: 'unused');

  @override
  Future<void> track(
    String eventType, {
    String? questId,
    String? category,
    int? availableMinutes,
    String? socialLevel,
    String? locationMode,
    int? questDurationMinutes,
    String? questDifficulty,
    double? estimatedCost,
    double? questLatitude,
    double? questLongitude,
    Map<String, dynamic> metadata = const {},
  }) async {}
}

/// What the quest screens read; a start fails the way the real repository
/// reports no connection.
class _FakeQuestRepository implements QuestRepository {
  List<UserQuest> attempts = [];
  List<QuestStep> steps = const [];
  List<PendingPhotoProof> pending = const [];
  int accepts = 0;

  @override
  bool catalogFromCache = true;

  @override
  bool userQuestsFromCache = true;

  @override
  Future<List<Quest>> getCatalog() async => catalog;

  List<Quest> catalog = [_quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => attempts;

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  UserQuest? activeAttempt({required String userId, required String questId}) => null;

  @override
  Future<UserQuest> acceptQuest({required String userId, required String questId}) async {
    accepts++;
    throw const AppException('Offline', isRetryable: true);
  }

  @override
  Future<void> saveExploreFilters(ExploreFilters filters) async {}

  @override
  StepSession? getActiveStepSession() => null;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => pending;

  @override
  Future<QuestPhotoProof> uploadPendingPhotoProof(PendingPhotoProof proof) async =>
      throw const AppException('Offline: your photo was saved.', isRetryable: true);

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

QuestViewModel _questViewModel(QuestRepository repository, {LocationService? location}) =>
    QuestViewModel(
      repository,
      _contextManager(location: location),
      _SilentTracker(),
      _userId,
      stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
      locationCheckIn: LocationCheckInService(
        requestAccess: () async => LocationAccess.granted,
        isLowBattery: () async => false,
        isOffline: () async => false,
        offlineChanges: () => const Stream.empty(),
        positions: (_, _) => const Stream.empty(),
      ),
      photoCapture: _NoLostPhoto(),
    );

/// Counts every call that would reach Supabase Auth.
class _FakeAuthRepository implements AuthRepository {
  int calls = 0;
  int signOuts = 0;

  @override
  bool get isAuthenticated => false;

  @override
  bool get isBiometricEnabled => false;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  @override
  String? get currentUserEmail => 'ana@example.com';

  @override
  Future<void> signIn({required String email, required String password}) async => calls++;

  @override
  Future<void> signUp({required String email, required String password}) async => calls++;

  @override
  Future<void> changePassword(String newPassword) async => calls++;

  @override
  Future<void> signOut() async => signOuts++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthViewModel _authViewModel(_FakeAuthRepository repository, {required bool offline}) => AuthViewModel(
  repository,
  BiometricService(),
  _SilentTracker(),
  isOffline: () async => offline,
  offlineChanges: () => const Stream.empty(),
);

/// gotrue's calls: [error] is thrown, or with [hang] they never answer.
class _AuthRemote implements SupabaseRemoteDataSource {
  Object? error;
  bool hang = false;

  Future<T> _answer<T>(T value) {
    if (hang) return Completer<T>().future;
    if (error != null) return Future.error(error!);
    return Future.value(value);
  }

  @override
  Future<AuthResponse> signIn({required String email, required String password}) =>
      _answer(AuthResponse());

  @override
  Future<UserResponse> updatePassword(String newPassword) =>
      _answer(UserResponse.fromJson({}));

  @override
  Future<void> signOut() => _answer(null);

  @override
  Future<void> upsertPreferences(Map<String, dynamic> preferences) => _answer(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocal implements LocalDataSource {
  bool cleared = false;
  Map<String, dynamic>? preferences;

  @override
  Future<void> clear() async => cleared = true;

  @override
  Future<void> cachePreferences(Map<String, dynamic> json) async => preferences = json;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ConnectivityViewModel', () {
    test('starts from what the device reports and follows its changes', () async {
      final connectivity = _FakeConnectivity(_none);
      final status = ConnectivityViewModel(connectivity: connectivity);
      addTearDown(status.dispose);

      await pumpEventQueue();
      expect(status.isOffline, isTrue);

      connectivity.set(_wifi);
      await pumpEventQueue();
      expect(status.isOffline, isFalse);

      connectivity.set(_none);
      await pumpEventQueue();
      expect(status.isOffline, isTrue);
    });

    test('a platform without the API counts as online', () async {
      final status = ConnectivityViewModel(connectivity: _NoConnectivityApi());
      addTearDown(status.dispose);

      await pumpEventQueue();

      expect(status.isOffline, isFalse);
    });
  });

  group('quest screens', () {
    late _FakeQuestRepository repository;
    late QuestViewModel viewModel;

    setUp(() {
      repository = _FakeQuestRepository();
      viewModel = _questViewModel(repository);
    });

    /// [home] on a small phone, with the device [offline] or not.
    Future<_FakeConnectivity> pumpScreen(WidgetTester tester, Widget home, {required bool offline}) async {
      tester.view.physicalSize = const Size(360, 690); // small phone: an overflow fails the test
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final connectivity = _FakeConnectivity(offline ? _none : _wifi);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
            Provider<LocationService>.value(value: _NoLocation()),
            Provider<WeatherService>.value(value: WeatherService()),
            ChangeNotifierProvider(create: (_) => ConnectivityViewModel(connectivity: connectivity)),
          ],
          child: MaterialApp(home: home),
        ),
      );
      await tester.pump(); // connectivity read, steps load after the first frame
      await tester.pump();
      return connectivity;
    }

    testWidgets('quest detail offline: the start is blocked and the reason is on screen', (tester) async {
      await pumpScreen(tester, const QuestDetailView(quest: _quest), offline: true);

      expect(find.text(OfflineMessages.startMission), findsOneWidget);
      expect(find.text('Accept quest →'), findsNothing);
      final button = find.widgetWithText(FilledButton, 'Offline');
      await tester.ensureVisible(button);
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(repository.accepts, 0);
    });

    testWidgets('quest detail online: "Aceptar misión" as before, with no notice', (tester) async {
      await pumpScreen(tester, const QuestDetailView(quest: _quest), offline: false);

      expect(find.text(OfflineMessages.startMission), findsNothing);
      expect(find.text('Accept quest →'), findsOneWidget);
    });

    testWidgets('quest detail offline: a mission already started can still be opened', (tester) async {
      repository.attempts = [_mission];
      await tester.runAsync(viewModel.load);

      await pumpScreen(tester, const QuestDetailView(quest: _quest), offline: true);

      final resume = find.widgetWithText(FilledButton, 'Continue quest →');
      await tester.ensureVisible(resume);
      expect(tester.widget<FilledButton>(resume).onPressed, isNotNull);
      expect(find.text(OfflineMessages.startMission), findsNothing);
    });

    test('starting refused for lack of connection says a connection is needed', () async {
      expect(await viewModel.acceptQuest('a'), isFalse);
      expect(viewModel.errorMessage, QuestViewModel.startNeedsConnectionMessage);
      expect(viewModel.currentMission, isNull);
    });

    testWidgets('Misión offline: steps visible, "Completar" blocked, leaving still possible', (
      tester,
    ) async {
      repository
        ..attempts = [_mission]
        ..steps = [_step(0), _step(1)];
      await tester.runAsync(viewModel.load);

      final connectivity = await pumpScreen(tester, const MissionTabView(), offline: true);

      expect(find.text(OfflineMessages.missionProgress), findsOneWidget);
      expect(find.text('Paso 0'), findsOneWidget);
      expect(find.text('Complete this step →'), findsNothing);
      final blocked = find.widgetWithText(FilledButton, 'Connect to complete');
      await tester.ensureVisible(blocked);
      expect(tester.widget<FilledButton>(blocked).onPressed, isNull);
      // Abandoning waits on the device and syncs later: it stays available.
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Exit')).onPressed,
        isNotNull,
      );

      connectivity.set(_wifi);
      await tester.pump();

      expect(find.text(OfflineMessages.missionProgress), findsNothing);
      expect(find.text('Complete this step →'), findsOneWidget);
    });

    testWidgets('Misión offline: a saved photo says it uploads by itself, with no retry button', (
      tester,
    ) async {
      repository
        ..attempts = [_mission]
        ..steps = [_step(0, 'photo')]
        ..pending = [
          PendingPhotoProof(
            localPath: '/tmp/p.jpg',
            storagePath: 'u/uq-a/a/0/p.jpg',
            attemptId: 'uq-a',
            questId: 'a',
            stepOrder: 0,
            sizeBytes: 10,
            capturedAt: DateTime(2026, 11, 1),
            lastError: 'Offline: your photo was saved.',
          ),
        ];
      await tester.runAsync(viewModel.load);

      await pumpScreen(tester, const MissionTabView(), offline: true);

      expect(find.text(OfflineMessages.photoUpload), findsOneWidget);
      expect(find.text('Retry upload'), findsNothing);
    });

    test('offline with no catalog ever saved: told apart from filters that exclude everything', () async {
      repository.catalog = [];
      await viewModel.load();
      expect(viewModel.catalogUnavailable, isTrue);

      repository
        ..catalog = [_quest]
        ..catalogFromCache = false;
      await viewModel.load();
      viewModel.setMinutes(10); // _quest takes 20 min: filtered out, but there is a catalog
      expect(viewModel.filteredCatalog, isEmpty);
      expect(viewModel.catalogUnavailable, isFalse);
    });

    test('"Activar ubicación": a GPS that throws ends the wait and says so', () async {
      final located = _questViewModel(repository, location: _BrokenLocation());

      await located.requestUserLocation();

      expect(located.isLocatingUser, isFalse);
      expect(located.userLocationUnavailable, isTrue);
      expect(located.userLatitude, isNull);
    });
  });

  group('auth', () {
    late _FakeAuthRepository repository;

    setUp(() => repository = _FakeAuthRepository());

    test('signing in offline is not even tried, and says why', () async {
      final viewModel = _authViewModel(repository, offline: true);

      expect(await viewModel.signIn(email: 'ana@example.com', password: 'secret'), isFalse);

      expect(repository.calls, 0);
      expect(viewModel.errorMessage, AuthViewModel.offlineSignInMessage);
      expect(viewModel.status, AuthStatus.unauthenticated);
    });

    test('signing up offline: same', () async {
      final viewModel = _authViewModel(repository, offline: true);

      expect(await viewModel.signUp(email: 'ana@example.com', password: 'secret'), isFalse);

      expect(repository.calls, 0);
      expect(viewModel.errorMessage, AuthViewModel.offlineSignUpMessage);
    });

    test('changing the password offline: not tried, with the reason', () async {
      final viewModel = _authViewModel(repository, offline: true);

      expect(await viewModel.changePassword('secret123'), AuthViewModel.offlinePasswordMessage);
      expect(repository.calls, 0);
    });

    test('online, signing in goes through as before', () async {
      final viewModel = _authViewModel(repository, offline: false);

      expect(await viewModel.signIn(email: 'ana@example.com', password: 'secret'), isTrue);
      expect(repository.calls, 1);
    });

    testWidgets('login screen offline: the reason on screen and "Log in" disabled', (tester) async {
      final connectivity = _FakeConnectivity(_none);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => _authViewModel(repository, offline: true)),
            ChangeNotifierProvider(create: (_) => ConnectivityViewModel(connectivity: connectivity)),
          ],
          child: const MaterialApp(home: LoginView()),
        ),
      );
      await tester.pump();

      expect(find.text(AuthViewModel.offlineSignInMessage), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Log in')).onPressed, isNull);

      connectivity.set(_wifi);
      await tester.pump();

      expect(find.text(AuthViewModel.offlineSignInMessage), findsNothing);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Log in')).onPressed,
        isNotNull,
      );
    });

    testWidgets('login screen with the keyboard open on a small phone: no overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 300); // what's left above a keyboard
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => _authViewModel(repository, offline: false),
          child: const MaterialApp(home: LoginView()),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('AuthRepository', () {
    late _AuthRemote remote;
    late _FakeLocal local;
    late AuthRepository repository;

    setUp(() {
      remote = _AuthRemote();
      local = _FakeLocal();
      repository = AuthRepository(remote, local);
    });

    test('no connection: a retryable message in Spanish, not gotrue\'s raw one', () async {
      remote.error = AuthRetryableFetchException(message: 'ClientException with SocketException');

      await expectLater(
        repository.signIn(email: 'ana@example.com', password: 'secret'),
        throwsA(
          isA<AppException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.message, 'message', startsWith('Could not connect')),
        ),
      );
    });

    testWidgets('a server that never answers: the sign-in ends after its limit', (tester) async {
      remote.hang = true;
      Object? error;
      unawaited(
        repository.changePassword('secret123').then((_) {}, onError: (Object e) => error = e),
      );

      await tester.pump(AuthRepository.requestTimeout);
      await tester.pump();

      expect(error, isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue));
    });

    testWidgets('signing out on a network that never answers still clears the device', (tester) async {
      remote.hang = true;
      var done = false;
      unawaited(repository.signOut().then((_) => done = true));

      await tester.pump(NetworkGuard.timeout);
      await tester.pump();

      expect(done, isTrue);
      expect(local.cleared, isTrue);
    });
  });

  group('preferences', () {
    late _AuthRemote remote;
    late _FakeLocal local;

    ProfileViewModel profileViewModel({required bool offline}) => ProfileViewModel(
      ProfileRepository(
        remote,
        local,
        network: NetworkGuard(isOffline: () async => offline),
      ),
      _FakeAuthRepository(),
      _userId,
    );

    setUp(() {
      remote = _AuthRemote();
      local = _FakeLocal();
    });

    test('saving with no connection: a retryable AppException, not a raw SocketException', () async {
      remote.error = const SocketException('Failed host lookup');
      final repository = ProfileRepository(remote, local);

      await expectLater(
        repository.updatePreferences(_userId, const UserPreferences()),
        throwsA(isA<AppException>().having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );
      expect(local.preferences, isNull);
    });

    Future<_FakeConnectivity> pumpPreferences(
      WidgetTester tester,
      ProfileViewModel viewModel, {
      required bool offline,
    }) async {
      final connectivity = _FakeConnectivity(offline ? _none : _wifi);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ProfileViewModel>.value(value: viewModel),
            ChangeNotifierProvider(create: (_) => ConnectivityViewModel(connectivity: connectivity)),
          ],
          child: const MaterialApp(home: EditPreferencesView()),
        ),
      );
      await tester.pump();
      return connectivity;
    }

    testWidgets('offline: "Save" disabled, with the reason', (tester) async {
      await pumpPreferences(tester, profileViewModel(offline: true), offline: true);

      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.scrollUntilVisible(save, 300); // last item of a lazy ListView
      await tester.pumpAndSettle();
      expect(find.text(OfflineMessages.savePreferences), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
    });

    testWidgets('a save that fails says why and the button works again (no endless spinner)', (
      tester,
    ) async {
      remote.error = const SocketException('Failed host lookup');
      await pumpPreferences(tester, profileViewModel(offline: false), offline: false);

      final save = find.widgetWithText(FilledButton, 'Save');
      await tester.scrollUntilVisible(save, 300); // last item of a lazy ListView
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Offline'), findsOneWidget);
      expect(find.byType(EditPreferencesView), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    });
  });
}
