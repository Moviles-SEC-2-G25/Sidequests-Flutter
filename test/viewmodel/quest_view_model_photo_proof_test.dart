import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_event_type.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/photo_proof_rules.dart';
import 'package:sidequests/core/verification/step_verification_strategy.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_check_in_service.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/photo_capture_service.dart';
import 'package:sidequests/data/services/step_counter_service.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/quests/mission_tab_view.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

const _questLat = 4.6473;
const _questLon = -74.0613;
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 7]);

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

ContextManager _contextManager() =>
    ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());

class _SpyTracker extends AnalyticsTracker {
  final List<(String, Map<String, dynamic>)> events = [];

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
  }) async => events.add((eventType, metadata));
}

class _FakeCamera extends PhotoCaptureService {
  Uint8List? next = _jpeg;
  Uint8List? lost;

  @override
  Future<Uint8List?> capture() async => next;

  @override
  Future<Uint8List?> retrieveLost() async => lost;
}

QuestStep _step(int order, String verificationType) => QuestStep(
  id: order,
  questId: 'ramen-spot',
  stepOrder: order,
  title: 'Step $order',
  verificationType: verificationType,
);

/// In-memory repository: the device-side pending list and the
/// server-side proofs, with a switchable upload failure.
class _FakeQuestRepository implements QuestRepository {
  final quest = const Quest(
    id: 'ramen-spot',
    title: 'Ramen',
    category: 'food',
    durationMinutes: 30,
    difficulty: 'easy',
    locationMode: 'gps',
    socialLevel: 'solo',
    latitude: _questLat,
    longitude: _questLon,
  );
  List<QuestStep> steps = [];
  final userQuests = [
    UserQuest(
      id: 'uq-1',
      userId: 'user-1',
      questId: 'ramen-spot',
      status: 'in_progress',
      acceptedAt: DateTime(2026, 1, 1),
    ),
  ];
  List<PendingPhotoProof> pending = [];
  final List<QuestPhotoProof> serverProofs = [];
  final List<UserQuest> progressUpdates = [];
  AppException? uploadFailure;
  int uploads = 0;

  @override
  Future<List<Quest>> getCatalog() async => [quest];

  @override
  Future<List<UserQuest>> getUserQuests(String userId) async => userQuests;

  @override
  Future<List<QuestStep>> getSteps(String questId) async => steps;

  @override
  Future<UserQuest> updateProgress(UserQuest userQuest) async {
    progressUpdates.add(userQuest);
    return userQuest;
  }

  @override
  StepSession? getActiveStepSession() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => [...pending];

  @override
  Future<List<QuestPhotoProof>> getPhotoProofs(String attemptId) async =>
      serverProofs.where((p) => p.attemptId == attemptId).toList();

  @override
  Future<PendingPhotoProof> savePendingPhotoProof({
    required UserQuest attempt,
    required int stepOrder,
    required Uint8List jpeg,
  }) async {
    if (!isJpeg(jpeg)) throw const AppException('La foto no es JPEG. Toma otra.');
    final proof = PendingPhotoProof(
      localPath: '/documents/pending_proofs/${pending.length}.jpg',
      storagePath: questProofStoragePath(
        userId: attempt.userId,
        attemptId: attempt.id,
        questId: attempt.questId,
        stepOrder: stepOrder,
        uniqueId: 'u${pending.length}',
      ),
      attemptId: attempt.id,
      questId: attempt.questId,
      stepOrder: stepOrder,
      sizeBytes: jpeg.length,
      capturedAt: DateTime(2026, 10, 1),
    );
    pending = [...pending.where((p) => p.stepOrder != stepOrder), proof];
    return proof;
  }

  @override
  Future<QuestPhotoProof> uploadPendingPhotoProof(PendingPhotoProof proof) async {
    uploads++;
    final failure = uploadFailure;
    if (failure != null) {
      pending = failure.isRetryable
          ? [for (final p in pending) p.storagePath == proof.storagePath ? p.failedWith(failure.message) : p]
          : pending.where((p) => p.storagePath != proof.storagePath).toList();
      throw failure;
    }
    pending = pending.where((p) => p.storagePath != proof.storagePath).toList();
    final registered = QuestPhotoProof(
      id: 'proof-$uploads',
      attemptId: proof.attemptId,
      stepOrder: proof.stepOrder,
      storagePath: proof.storagePath,
      uploadedAt: DateTime(2026, 10, 1),
    );
    serverProofs.add(registered);
    return registered;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late _FakeQuestRepository repository;
  late _FakeCamera camera;
  late _SpyTracker tracker;
  late StreamController<CheckInFix> gps;
  late QuestViewModel viewModel;

  setUp(() {
    repository = _FakeQuestRepository();
    camera = _FakeCamera();
    tracker = _SpyTracker();
    gps = StreamController<CheckInFix>.broadcast();
    viewModel = QuestViewModel(
      repository,
      _contextManager(),
      tracker,
      'user-1',
      stepCounter: StepCounterService(requestAccess: () async => StepCounterStatus.unavailable),
      locationCheckIn: LocationCheckInService(
        requestAccess: () async => LocationAccess.granted,
        isLowBattery: () async => false,
        positions: (_, _) => gps.stream,
      ),
      photoCapture: camera,
    );
  });

  Future<void> openMission(List<QuestStep> steps) async {
    repository.steps = steps;
    await viewModel.load();
    await viewModel.loadSteps('ramen-spot');
    await _flush();
  }

  QuestStep currentStep() => repository.steps[viewModel.currentMission!.currentStep];

  VerificationResult photoResult() {
    final part = viewModel
        .verificationStrategyFor(currentStep())
        .parts
        .firstWhere((p) => p.needsPhoto);
    return viewModel.verificationResultFor(part, repository.quest);
  }

  bool canComplete() => viewModel.canCompleteCurrentStep(currentStep(), repository.quest);

  List<Map<String, dynamic>> uploadEvents() => [
    for (final (type, metadata) in tracker.events)
      if (type == AnalyticsEventType.photoProofUploaded) metadata,
  ];

  test('photo step: blocked until the photo is uploaded; "Tomar foto" uploads and unblocks it', () async {
    await openMission([_step(0, 'photo'), _step(1, 'none')]);
    expect(photoResult(), isA<Pending>());
    expect(canComplete(), isFalse);

    await viewModel.capturePhotoProof();

    expect(repository.uploads, 1);
    expect(photoResult(), isA<Verified>());
    expect(canComplete(), isTrue);
    expect(viewModel.pendingPhotoProofs, isEmpty);
    // A photo-only step still needs the tap: only location is automatic.
    expect(repository.progressUpdates, isEmpty);
  });

  test('photo_proof_uploaded is emitted once, after registration, with its metadata', () async {
    await openMission([_step(0, 'photo'), _step(1, 'none')]);

    await viewModel.capturePhotoProof();

    expect(uploadEvents().single, {
      'attempt_id': 'uq-1',
      'step_order': 0,
      'was_retry': false,
      'size_bytes': _jpeg.length,
    });
  });

  test('backing out of the camera stores and uploads nothing', () async {
    await openMission([_step(0, 'photo'), _step(1, 'none')]);
    camera.next = null;

    await viewModel.capturePhotoProof();

    expect(repository.pending, isEmpty);
    expect(repository.uploads, 0);
    expect(viewModel.photoErrorMessage, isNull);
  });

  test('offline: the photo waits on the device, "Reintentar subida" uploads it later', () async {
    await openMission([_step(0, 'photo'), _step(1, 'none')]);
    repository.uploadFailure = const AppException('Sin conexión: tu foto quedó guardada.', isRetryable: true);

    await viewModel.capturePhotoProof();

    expect(viewModel.currentPendingPhotoProof?.lastError, contains('Sin conexión'));
    expect(canComplete(), isFalse);
    expect(uploadEvents(), isEmpty); // no event for a failed upload

    repository.uploadFailure = null;
    await viewModel.retryPhotoUpload();

    expect(viewModel.currentPendingPhotoProof, isNull);
    expect(canComplete(), isTrue);
    expect(uploadEvents().single['was_retry'], isTrue);
  });

  test('rejected (not retryable): explains why, keeps nothing, still blocked', () async {
    await openMission([_step(0, 'photo'), _step(1, 'none')]);
    repository.uploadFailure = const AppException('Este paso no admite foto o la misión no es tuya.');

    await viewModel.capturePhotoProof();

    expect(viewModel.photoErrorMessage, contains('no admite foto'));
    expect(viewModel.currentPendingPhotoProof, isNull);
    expect(canComplete(), isFalse);
  });

  test('a non-JPEG capture is refused before anything is stored', () async {
    await openMission([_step(0, 'photo'), _step(1, 'none')]);
    camera.next = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

    await viewModel.capturePhotoProof();

    expect(viewModel.photoErrorMessage, contains('JPEG'));
    expect(repository.uploads, 0);
  });

  test('photo_and_location: already at the place, the upload completes the step on its own', () async {
    await openMission([_step(0, 'photo_and_location'), _step(1, 'none')]);
    gps.add(const CheckInFix(latitude: _questLat, longitude: _questLon, accuracyMeters: 5));
    await _flush();
    expect(repository.progressUpdates, isEmpty); // location ✓, photo missing

    await viewModel.capturePhotoProof();
    await _flush();

    expect(repository.progressUpdates.single.currentStep, 1);
  });

  test('a proof already on the server (reinstall, new phone) counts when the mission opens', () async {
    repository.serverProofs.add(
      QuestPhotoProof(
        id: 'p',
        attemptId: 'uq-1',
        stepOrder: 0,
        storagePath: 'user-1/uq-1/ramen-spot/step-1-x.jpg',
        uploadedAt: DateTime(2026, 9, 30),
      ),
    );

    await openMission([_step(0, 'photo'), _step(1, 'none')]);

    expect(photoResult(), isA<Verified>());
    expect(canComplete(), isTrue);
  });

  test('a photo left pending by an earlier session is retried automatically on load', () async {
    repository.pending = [
      PendingPhotoProof(
        localPath: '/documents/pending_proofs/old.jpg',
        storagePath: 'user-1/uq-1/ramen-spot/step-1-old.jpg',
        attemptId: 'uq-1',
        questId: 'ramen-spot',
        stepOrder: 0,
        sizeBytes: 5,
        capturedAt: DateTime(2026, 9, 30),
        attempts: 1,
        lastError: 'Sin conexión',
      ),
    ];

    await openMission([_step(0, 'photo'), _step(1, 'none')]);

    expect(repository.uploads, 1);
    expect(repository.pending, isEmpty);
    expect(uploadEvents().single['was_retry'], isTrue);
  });

  test('a photo Android handed back after killing the app is uploaded on open', () async {
    camera.lost = _jpeg;
    await openMission([_step(0, 'photo'), _step(1, 'none')]);

    await viewModel.recoverLostPhotoProof();

    expect(repository.uploads, 1);
    expect(photoResult(), isA<Verified>());
  });

  testWidgets('Misión tab: "Tomar foto", then "Reintentar subida" offline, "Completar" disabled', (tester) async {
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => openMission([_step(0, 'photo'), _step(1, 'none')]));

    await tester.pumpWidget(
      ChangeNotifierProvider<QuestViewModel>.value(
        value: viewModel,
        child: const MaterialApp(home: MissionTabView()),
      ),
    );
    await tester.pump();

    expect(find.text('Tomar foto'), findsOneWidget);
    final completeButton = find.widgetWithText(FilledButton, 'Completar este paso →');
    expect(tester.widget<FilledButton>(completeButton).onPressed, isNull);

    repository.uploadFailure = const AppException('Sin conexión: tu foto quedó guardada.', isRetryable: true);
    await tester.runAsync(viewModel.capturePhotoProof);
    await tester.pump();

    expect(find.text('Reintentar subida'), findsOneWidget);
    expect(find.text('Sin conexión: tu foto quedó guardada.'), findsOneWidget);
    expect(tester.widget<FilledButton>(completeButton).onPressed, isNull);
  });
}
