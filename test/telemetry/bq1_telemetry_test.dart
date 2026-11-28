import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/telemetry/app_module.dart';
import 'package:sidequests/telemetry/bq1_telemetry.dart';
import 'package:sidequests/telemetry/resume_session_tracker.dart';
import 'package:sidequests/telemetry/telemetry_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final t0 = DateTime(2026, 11, 27, 18);
  const minute = Duration(minutes: 1);

  group('ResumeSessionTracker (same cases as Kotlin)', () {
    test('resume after more than 10 minutes with an active Nearby quest qualifies', () {
      final tracker = ResumeSessionTracker()..onBackground(t0, 'botanical-garden');

      final resume = tracker.onForeground(t0.add(minute * 11));

      expect(resume, isNotNull);
      expect(resume!.questId, 'botanical-garden');
      expect(resume.background, minute * 11);
    });

    test('short background or no Nearby quest does not qualify', () {
      final tracker = ResumeSessionTracker()..onBackground(t0, 'botanical-garden');
      expect(tracker.onForeground(t0.add(minute * 9)), isNull);

      tracker.onBackground(t0, null);
      expect(tracker.onForeground(t0.add(minute * 30)), isNull);
    });

    test('failures are attributed to the resume only during the 5-minute window', () {
      final tracker = ResumeSessionTracker()..onBackground(t0, 'q1');
      final resumedAt = t0.add(minute * 15);
      tracker.onForeground(resumedAt);

      expect(tracker.activeResume(resumedAt.add(minute * 4)), isNotNull);
      expect(tracker.activeResume(resumedAt.add(minute * 6)), isNull);
    });

    test('a background period restored after the app was killed is still detected', () {
      final tracker = ResumeSessionTracker()..restore(t0, 'q1');

      expect(tracker.onForeground(t0.add(minute * 20)), isNotNull);
    });
  });

  group('ModuleClassifier', () {
    test('maps the first app frame to its module', () {
      final trace = StackTrace.fromString(
        '#0      Object.noSuchMethod (dart:core-patch/object_patch.dart:38:5)\n'
        '#1      ReverseGeocodingService.areaFor (package:sidequests/data/services/reverse_geocoding_service.dart:80:3)\n'
        '#2      QuestViewModel._updateArea (package:sidequests/viewmodel/quests/quest_view_model.dart:600:5)\n',
      );

      expect(ModuleClassifier.fromStackTrace(trace), AppModule.geocoding);
    });

    test('more specific paths win, and unknown code stays unknown', () {
      expect(ModuleClassifier.fromPath('data/services/photo_capture_service.dart:1'), AppModule.photoProof);
      expect(ModuleClassifier.fromPath('data/services/location_service.dart:1'), AppModule.context);
      expect(ModuleClassifier.fromPath('repository/auth_repository.dart:1'), AppModule.auth);
      expect(ModuleClassifier.fromPath('repository/quest_repository.dart:1'), AppModule.catalog);
      expect(ModuleClassifier.fromPath('view/home_shell.dart:1'), AppModule.ui);
      expect(ModuleClassifier.fromStackTrace(StackTrace.fromString('#0 main (dart:core)')), AppModule.unknown);
    });
  });

  group('Bq1Telemetry queue', () {
    late TelemetryStore store;
    late List<List<PendingTelemetryEvent>> sent;
    late bool failSend;
    late DateTime now;
    late Bq1Telemetry telemetry;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = TelemetryStore(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
      sent = [];
      failSend = true;
      now = t0;
      telemetry = Bq1Telemetry(
        store: store,
        sender: (events) async {
          if (failSend) throw Exception('offline');
          sent.add(events);
        },
        isOnline: () async => !failSend,
        now: () => now,
      );
      await telemetry.init(listenToLifecycle: false);
    });

    tearDown(() async {
      telemetry.dispose();
      await store.close();
    });

    Future<List<Map<String, dynamic>>> queued() async => [
      for (final event in await store.oldest(100)) jsonDecode(event.metadataJson) as Map<String, dynamic>,
    ];

    test('offline, failures stay queued with their module and resume tag', () async {
      telemetry.activeNearbyQuestId = () => 'q-gps';
      telemetry.onAppBackground();
      now = t0.add(minute * 12);
      telemetry.onAppForeground();
      await telemetry.settle();
      now = now.add(minute * 2);
      telemetry.report(AppModule.recommendations, Exception('timeout'));
      await telemetry.settle();

      final events = await store.oldest(10);
      expect(events.map((e) => e.eventType), ['bq1_resume_after_background', 'module_failure']);
      final failure = (await queued()).last;
      expect(failure['module'], 'recommendations');
      expect(failure['fatal'], isFalse);
      expect(failure['after_long_resume'], isTrue);
      expect(failure['seconds_since_resume'], 120);
      expect(failure['quest_id'], 'q-gps');
      expect(failure['online'], isFalse);
      expect(telemetry.pendingCount.value, 2);
    });

    test('back online, the queue is uploaded and emptied', () async {
      telemetry.report(AppModule.catalog, null, message: 'fell back to cache');
      await telemetry.settle();
      expect(await store.count(), 1);

      failSend = false;
      telemetry.scheduleUpload();
      await telemetry.settle();

      expect(sent.single.single.eventType, 'module_failure');
      expect(await store.count(), 0);
      expect(telemetry.pendingCount.value, 0);
    });

    test('an uncaught error is classified from its stack trace and marked fatal', () async {
      telemetry.recordUncaught(
        StateError('boom'),
        StackTrace.fromString('#0 X (package:sidequests/data/services/step_counter_service.dart:1:1)'),
      );
      await telemetry.settle();

      final failure = (await queued()).single;
      expect(failure['module'], 'sensors');
      expect(failure['fatal'], isTrue);
      expect(failure['exception'], 'StateError');
      expect(failure['after_long_resume'], isFalse);
    });
  });
}
