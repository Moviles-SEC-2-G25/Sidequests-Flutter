import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/biometric_service.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/photo_capture_service.dart';
import 'package:sidequests/data/services/reverse_geocoding_service.dart';
import 'package:sidequests/data/services/shake_detector.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/user_preferences.dart';
import 'package:sidequests/repository/auth_repository.dart';
import 'package:sidequests/repository/profile_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/repository/social_repository.dart';
import 'package:sidequests/view/home_shell.dart';
import 'package:sidequests/viewmodel/auth/auth_view_model.dart';
import 'package:sidequests/viewmodel/profile/profile_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';
import 'package:sidequests/viewmodel/social/social_view_model.dart';
import 'package:sidequests/viewmodel/theme_view_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState, Session;

// The rest of the suite covers each piece with fakes. Here only the network is
// fake: a real Hive box and real files on disk, closed and reopened like an
// app restart, with every Supabase call failing while offline.

const _userId = 'user-1';
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 7, 8, 9]);

/// Supabase in memory. [offline] fails every call like a dropped connection,
/// and [calls] counts the ones that were attempted.
class _FakeRemote implements SupabaseRemoteDataSource {
  bool offline = false;
  int calls = 0;
  String stepType = 'none';
  final List<Map<String, dynamic>> userQuests = [];
  final Map<String, Uint8List> uploads = {};
  final List<Map<String, dynamic>> proofs = [];

  @override
  String? get currentUserEmail => 'ana@uniandes.edu.co';

  @override
  Session? get currentSession => null;

  @override
  Stream<AuthState> get authStateChanges => const Stream.empty();

  void _call() {
    calls++;
    if (offline) throw const SocketException('offline');
  }

  @override
  Future<List<Map<String, dynamic>>> getActiveQuests() async {
    _call();
    return [
      {
        'id': 'a',
        'title': 'Quest a',
        'category': 'food',
        'duration_minutes': 20,
        'difficulty': 'easy',
        'location_mode': 'anywhere',
        'social_level': 'solo',
      },
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestSteps(String questId) async {
    _call();
    return [
      {'id': 1, 'quest_id': questId, 'step_order': 0, 'title': 'Uno', 'verification_type': stepType},
      {'id': 2, 'quest_id': questId, 'step_order': 1, 'title': 'Dos', 'verification_type': 'none'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> getUserQuests(String userId) async {
    _call();
    return [...userQuests];
  }

  @override
  Future<Map<String, dynamic>> upsertUserQuest(Map<String, dynamic> userQuest) async {
    _call();
    final id = userQuest['id'] ?? 'uq-1';
    final existing = userQuests.where((row) => row['id'] == id).firstOrNull;
    final row = {'accepted_at': '2026-10-01T10:00:00Z', ...?existing, ...userQuest, 'id': id};
    userQuests
      ..removeWhere((r) => r['id'] == id)
      ..insert(0, row);
    return row;
  }

  @override
  Future<void> uploadQuestProof(String storagePath, Uint8List jpeg) async {
    _call();
    uploads[storagePath] = jpeg;
  }

  @override
  Future<Map<String, dynamic>> insertQuestPhotoProof({
    required String attemptId,
    required int stepOrder,
    required String storagePath,
  }) async {
    _call();
    final row = {
      'id': 'proof-${proofs.length}',
      'attempt_id': attemptId,
      'step_order': stepOrder,
      'storage_path': storagePath,
      'uploaded_at': '2026-10-31T12:00:00Z',
    };
    proofs.add(row);
    return row;
  }

  @override
  Future<List<Map<String, dynamic>>> getQuestPhotoProofs(String attemptId) async {
    _call();
    return [...proofs];
  }

  @override
  Future<List<Map<String, dynamic>>> recommendQuests({
    required int availableMinutes,
    required String socialLevel,
    List<String> interests = const [],
    String locationMode = 'all',
    List<String> excludedQuestIds = const [],
    int limit = 3,
  }) async {
    _call();
    return [];
  }

  @override
  Future<Map<String, dynamic>> getProfile(String userId) async {
    _call();
    return {'id': userId, 'display_name': 'Ana'};
  }

  @override
  Future<Map<String, dynamic>> getPreferences(String userId) async {
    _call();
    return {'user_id': userId};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Everything HomeShell's tabs read, in memory: real Hive's writes would wait
/// on a queue testWidgets' fake clock never runs. The tests above cover the
/// disk; this one covers the way from a connectivity change to the upload.
class _MemoryLocal implements LocalDataSource {
  List<Map<String, dynamic>> catalog = [];
  List<Map<String, dynamic>> userQuests = [];
  List<Map<String, dynamic>> pendingPhotos = [];
  final Map<String, List<Map<String, dynamic>>> steps = {};
  final Map<String, List<Map<String, dynamic>>> proofs = {};
  final Map<String, Uint8List> files = {};

  @override
  bool get canKeepPhotoFiles => true;

  @override
  List<Map<String, dynamic>> getPendingPhotoProofs() => [...pendingPhotos];

  @override
  Future<void> savePendingPhotoProofs(List<Map<String, dynamic>> photos) async =>
      pendingPhotos = photos;

  @override
  Future<Uint8List?> readPendingProofFile(String path) async => files[path];

  @override
  Future<void> deletePendingProofFile(String path) async => files.remove(path);

  @override
  List<Map<String, dynamic>>? getPhotoProofs(String attemptId) => proofs[attemptId];

  @override
  Future<void> cachePhotoProofs(String attemptId, List<Map<String, dynamic>> rows) async =>
      proofs[attemptId] = rows;

  @override
  List<Map<String, dynamic>> getQuestCatalog() => catalog;

  @override
  Future<void> cacheQuestCatalog(List<Map<String, dynamic>> quests) async => catalog = quests;

  @override
  List<Map<String, dynamic>>? getQuestSteps(String questId) => steps[questId];

  @override
  Future<void> cacheQuestSteps(String questId, List<Map<String, dynamic>> rows) async =>
      steps[questId] = rows;

  @override
  List<Map<String, dynamic>> getUserQuests() => [...userQuests];

  @override
  Future<void> cacheUserQuests(List<Map<String, dynamic>> rows) async => userQuests = rows;

  @override
  Map<String, dynamic>? getActiveStepSession() => null;

  @override
  Map<String, dynamic>? getVerifiedCheckIn() => null;

  @override
  List<Map<String, dynamic>> getPendingWrites() => const [];

  @override
  List<Map<String, dynamic>> getPendingAnalyticsEvents() => const [];

  @override
  ({String batchId, List<Map<String, dynamic>> rows})? getSavedRecommendations() => null;

  @override
  Map<String, dynamic>? getExploreFilters() => null;

  @override
  Future<void> saveExploreFilters(Map<String, dynamic> filters) async {}

  @override
  Map<String, dynamic>? getProfile() => null;

  @override
  Future<void> cacheProfile(Map<String, dynamic> profile) async {}

  @override
  Map<String, dynamic>? getPreferences() => null;

  @override
  Future<void> cachePreferences(Map<String, dynamic> preferences) async {}

  @override
  bool isDarkMode() => false;

  @override
  bool isBiometricEnabled() => false;

  @override
  bool missionNotificationsEnabled() => true;

  @override
  bool dailyRemindersEnabled() => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

/// The real plugin's channel never answers under testWidgets' fake clock.
class _FakeConnectivity implements Connectivity {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [ConnectivityResult.none];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ContextManager _contextManager() => ContextManager(
  locationService: _NoLocation(),
  batteryMonitor: _FullBattery(),
  connectivity: _FakeConnectivity(),
);

class _SpyTracker extends AnalyticsTracker {
  final List<({String type, Map<String, dynamic> metadata})> calls = [];

  _SpyTracker()
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
  }) async => calls.add((type: eventType, metadata: metadata));
}

class _FakeCamera extends PhotoCaptureService {
  @override
  Future<Uint8List?> capture() async => _jpeg;

  @override
  Future<Uint8List?> retrieveLost() async => null;
}

void main() {
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  late Directory documents;
  late LocalDataSource hive;
  late QuestRepository repository;
  late _FakeRemote remote;
  late _SpyTracker tracker;

  /// An app restart: what was running is gone, and the box is closed and
  /// reopened from disk.
  Future<void> restart({QuestViewModel? running}) async {
    running?.dispose();
    await Hive.close();
    hive = LocalDataSource();
    await hive.init();
    repository = QuestRepository(remote, hive);
  }

  QuestViewModel newViewModel({Stream<int>? sensor}) => QuestViewModel(
    repository,
    _contextManager(),
    tracker,
    _userId,
    stepCounter: StepCounterService(
      cumulativeSteps: () => sensor ?? const Stream.empty(),
      requestAccess: () async =>
          sensor == null ? StepCounterStatus.unavailable : StepCounterStatus.counting,
      openSettings: () async => true,
    ),
    locationCheckIn: LocationCheckInService(
      requestAccess: () async => LocationAccess.granted,
      isLowBattery: () async => false,
      isOffline: () async => false,
      offlineChanges: () => const Stream.empty(),
      positions: (_, _) => const Stream.empty(),
    ),
    photoCapture: _FakeCamera(),
  );

  /// Unawaited Hive writes and file operations are real disk I/O.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

  /// Online: accepts the mission and opens it, so everything gets cached.
  Future<QuestViewModel> acceptOnline({Stream<int>? sensor}) async {
    final viewModel = newViewModel(sensor: sensor);
    await viewModel.load();
    await viewModel.acceptQuest('a');
    await viewModel.loadSteps('a');
    await settle();
    return viewModel;
  }


  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    documents = await Directory.systemTemp.createTemp('offline_device_features_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (_) async => documents.path,
    );
    SharedPreferences.setMockInitialValues({});
    remote = _FakeRemote();
    tracker = _SpyTracker();
    await restart();
  });

  tearDown(() async {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      null,
    );
    await documents.delete(recursive: true);
  });

  group('(a) podómetro', () {
    late StreamController<int> sensor;

    setUp(() => sensor = StreamController<int>.broadcast());

    Future<void> walk(int cumulativeSteps) async {
      sensor.add(cumulativeSteps);
      await settle();
    }

    test('without a network it counts and writes the session, attempting no call', () async {
      final viewModel = await acceptOnline(sensor: sensor.stream);
      remote.offline = true;
      remote.calls = 0;

      await walk(1000);
      await walk(1080);

      expect(viewModel.missionSteps, 80);
      expect(hive.getActiveStepSession(), {
        'user_quest_id': 'uq-1',
        'carried': 0,
        'baseline': 1000,
        'last_reading': 1080,
      });
      expect(remote.calls, 0);
    });

    test('a step that fails to save offline does not stop the count', () async {
      final viewModel = await acceptOnline(sensor: sensor.stream);
      remote.offline = true;
      await walk(1000);

      await viewModel.completeCurrentStep(viewModel.currentMission!);
      expect(viewModel.stepErrorMessage, isNotNull);

      await walk(1050);
      expect(viewModel.missionSteps, 50);
      expect(viewModel.stepStatus, StepCounterStatus.counting);
    });

    test('restarting offline restores the session, with the steps walked while closed', () async {
      final running = await acceptOnline(sensor: sensor.stream);
      await walk(1000);
      await walk(1040);
      remote.offline = true;

      await restart(running: running);
      final restored = newViewModel(sensor: sensor.stream);
      await restored.load();
      await settle();

      expect(restored.currentMission?.id, 'uq-1');
      expect(restored.stepTrackedUserQuestId, 'uq-1');
      expect(restored.stepStatus, StepCounterStatus.counting);
      expect(restored.missionSteps, 40); // the last reading written to disk

      await walk(1300); // the OS kept counting while the app was closed
      expect(restored.missionSteps, 300);
    });

    test('the total is saved once the mission can finish, and survives another restart', () async {
      final running = await acceptOnline(sensor: sensor.stream);
      await walk(1000);
      remote.offline = true;
      await restart(running: running);
      final restored = newViewModel(sensor: sensor.stream);
      await restored.load();
      await restored.loadSteps('a');
      await settle();
      await walk(1120);

      remote.offline = false;
      await restored.completeCurrentStep(restored.currentMission!); // Uno
      await restored.completeCurrentStep(restored.currentMission!); // Dos: the last
      await settle();

      expect(restored.currentMission, isNull);
      expect(hive.getActiveStepSession(), isNull);
      await restart(running: restored);
      expect(repository.getStepTotals(), {'uq-1': 120});
    });
  });

  group('(f) foto', () {
    setUp(() => remote.stepType = 'photo');

    bool canComplete(QuestViewModel viewModel) {
      final step = viewModel.stepsOf('a')[viewModel.currentMission!.currentStep];
      return viewModel.canCompleteCurrentStep(step, viewModel.questById('a')!);
    }

    Future<QuestViewModel> captureOffline() async {
      final viewModel = await acceptOnline();
      remote.offline = true;
      await viewModel.capturePhotoProof();
      await settle();
      return viewModel;
    }

    test('offline it stays pending, as a real file, and the step stays blocked', () async {
      final viewModel = await captureOffline();

      final pending = viewModel.currentPendingPhotoProof!;
      expect(pending.lastError, contains('Sin conexión'));
      expect(await File(pending.localPath).readAsBytes(), _jpeg);
      expect(hive.getPendingPhotoProofs(), hasLength(1));
      expect(remote.uploads, isEmpty);
      expect(canComplete(viewModel), isFalse);
    });

    test('it survives restarting offline: same photo, and an automatic try that fails', () async {
      final running = await captureOffline();
      final before = running.currentPendingPhotoProof!;

      await restart(running: running);
      final restored = newViewModel();
      await restored.load();
      await restored.loadSteps('a');
      await settle();

      final pending = restored.currentPendingPhotoProof!;
      expect(pending.storagePath, before.storagePath);
      expect(pending.attempts, greaterThan(before.attempts));
      expect(await File(pending.localPath).readAsBytes(), _jpeg);
      expect(remote.uploads, isEmpty);
      expect(canComplete(restored), isFalse);
    });

    test('the view model reconnecting uploads it, once, with the same bytes and path', () async {
      final running = await captureOffline();
      final before = running.currentPendingPhotoProof!;
      await restart(running: running);
      final restored = newViewModel();
      await restored.load();
      await restored.loadSteps('a');
      await settle();

      remote.offline = false;
      await restored.refreshAfterReconnect(const UserPreferences());
      await settle();

      expect(remote.uploads.keys, [before.storagePath]);
      expect(remote.uploads.values.single, _jpeg);
      expect(remote.proofs.single['storage_path'], before.storagePath);
      expect(hive.getPendingPhotoProofs(), isEmpty);
      expect(await File(before.localPath).exists(), isFalse);
      expect(restored.currentPendingPhotoProof, isNull);
      expect(canComplete(restored), isTrue);

      final event = tracker.calls.singleWhere((c) => c.type == AnalyticsEventType.photoProofUploaded);
      expect(event.metadata['was_retry'], isTrue);
      expect(event.metadata['storage_path'], before.storagePath);
    });

    group('HomeShell._refreshAfterReconnect', () {
      const channels = [
        'dev.fluttercommunity.plus/connectivity',
        'dev.fluttercommunity.plus/connectivity_status',
        'dev.fluttercommunity.plus/battery',
        'dev.fluttercommunity.plus/charging',
      ];
      const status = EventChannel('dev.fluttercommunity.plus/connectivity_status');

      /// The real ContextStatusViewModel over the plugins' channels, offline at
      /// first; returns what emits later connectivity changes.
      MockStreamHandlerEventSink Function() mockPluginsOffline() {
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
            return switch (call.method) {
              'check' => ['none'],
              'getBatteryLevel' => 100,
              _ => null,
            };
          });
        }
        late MockStreamHandlerEventSink events;
        messenger.setMockStreamHandler(
          status,
          MockStreamHandler.inline(
            onListen: (_, sink) {
              events = sink;
            },
          ),
        );
        addTearDown(() {
          messenger.setMockStreamHandler(status, null);
          for (final channel in channels) {
            messenger.setMockMethodCallHandler(MethodChannel(channel), null);
          }
        });
        return () => events;
      }

      Future<void> pumpShell(
        WidgetTester tester,
        QuestViewModel viewModel,
        LocalDataSource local,
      ) async {
        final authRepository = AuthRepository(remote, local);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider<LocalDataSource>.value(value: local),
              Provider<AnalyticsTracker>.value(value: tracker),
              Provider<LocationService>.value(value: _NoLocation()),
              Provider<WeatherService>.value(value: WeatherService()),
              Provider<ReverseGeocodingService>(
                create: (_) => ReverseGeocodingService(localDataSource: local),
              ),
              ChangeNotifierProvider(create: (_) => ThemeViewModel(local)),
              ChangeNotifierProvider(
                create: (_) => AuthViewModel(authRepository, BiometricService(), tracker),
              ),
              ChangeNotifierProvider<QuestViewModel>.value(value: viewModel),
              ChangeNotifierProvider(
                create: (_) => ProfileViewModel(
                  ProfileRepository(remote, local),
                  authRepository,
                  _userId,
                ),
              ),
              ChangeNotifierProvider(create: (_) => SocialViewModel(SocialRepository())),
            ],
            child: MaterialApp(
              home: HomeShell(
                shakeDetector: ShakeDetector(
                  accelerometerEvents: const Stream.empty(),
                  now: () => DateTime(2026, 10, 31),
                ),
              ),
            ),
          ),
        );
      }

      testWidgets('a restored pending photo goes up alone, with no tap', (tester) async {
        final connectivity = mockPluginsOffline();
        const localPath = 'pending/photo.jpg';
        const storagePath = 'user-1/uq-1/a/step-1-saved.jpg';
        final attempt = {
          'id': 'uq-1',
          'user_id': _userId,
          'quest_id': 'a',
          'status': 'accepted',
          'accepted_at': '2026-10-01T10:00:00Z',
        };
        remote.userQuests.add(attempt);
        remote.offline = true;
        final local = _MemoryLocal()
          ..userQuests = [attempt]
          ..files[localPath] = _jpeg
          ..pendingPhotos = [
            PendingPhotoProof(
              localPath: localPath,
              storagePath: storagePath,
              attemptId: 'uq-1',
              questId: 'a',
              stepOrder: 0,
              sizeBytes: _jpeg.length,
              capturedAt: DateTime.utc(2026, 10, 31),
              verificationType: 'photo',
            ).toJson(),
          ];
        repository = QuestRepository(remote, local);

        await pumpShell(tester, newViewModel(), local);
        await tester.pumpAndSettle();
        expect(remote.uploads, isEmpty);
        expect(local.pendingPhotos, hasLength(1));

        remote.offline = false;
        connectivity().success(['wifi']);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2)); // the connection hasn't held yet
        expect(remote.uploads, isEmpty);

        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(remote.uploads.keys, [storagePath]);
        expect(remote.uploads.values.single, _jpeg);
        expect(remote.proofs.single['storage_path'], storagePath);
        expect(local.pendingPhotos, isEmpty);
        expect(local.files, isEmpty);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    });
  });
}
