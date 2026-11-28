import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/core/app_exception.dart';
import 'package:sidequests/core/app_theme.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/offline_pack_manifest_store.dart';
import 'package:sidequests/data/offline/offline_pack_manager.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/models/photo_proof.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/step_session.dart';
import 'package:sidequests/models/verified_check_in.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/profile/offline_pack_view.dart';
import 'package:sidequests/view/widgets/offline_notice.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';
import 'package:sidequests/viewmodel/offline/offline_pack_view_model.dart';
import 'package:sidequests/viewmodel/quests/quest_view_model.dart';

Quest _quest(String id, String title, String emoji) => Quest(
  id: id,
  title: title,
  category: 'food',
  emoji: emoji,
  durationMinutes: 30,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'solo',
);

final _catalog = [
  _quest('ramen', 'Ramen escondido', '🍜'),
  _quest('mural', 'Ruta de murales', '🎨'),
  _quest('mercado', 'Mercado de Paloquemao', '🍍'),
];

List<QuestStep> _steps(String questId) => [
  QuestStep(id: 1, questId: questId, stepOrder: 0, title: 'Llega', description: 'Busca la entrada.'),
];

/// Hive cache and server in memory. [serverDown] fails the step requests.
class _FakeRepository implements QuestRepository {
  final savedSteps = <String, List<QuestStep>>{};
  bool serverDown = false;

  @override
  bool catalogFromCache = false;

  @override
  List<Quest> getCachedCatalog() => _catalog;

  @override
  bool hasCachedSteps(String questId) => savedSteps.containsKey(questId);

  @override
  List<QuestStep>? getCachedSteps(String questId) => savedSteps[questId];

  @override
  Future<List<Quest>> getCatalog() async => _catalog;

  @override
  Future<List<QuestStep>> getSteps(String questId) async {
    if (serverDown) throw const AppException('Offline', isRetryable: true);
    return savedSteps[questId] = _steps(questId);
  }

  // What QuestViewModel reads when it's created.
  @override
  StepSession? getActiveStepSession() => null;

  @override
  VerifiedCheckIn? getVerifiedCheckIn() => null;

  @override
  List<PendingPhotoProof> getPendingPhotoProofs() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnectivity implements Connectivity {
  final bool offline;

  _FakeConnectivity({required this.offline});

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      [offline ? ConnectivityResult.none : ConnectivityResult.wifi];

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

class _FullBattery extends BatteryMonitor {
  @override
  Future<bool> isLow() async => false;
}

class _NullSink implements AnalyticsEventSink {
  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {}
}

void main() {
  late _FakeRepository repository;
  late OfflinePackManager manager;
  late OfflinePackViewModel pack;
  late QuestViewModel questViewModel;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = _FakeRepository();
    // The web store: SharedPreferences in memory, no disk under the fake clock.
    manager = OfflinePackManager(repository, OfflinePackManifestStore(isWeb: true));
    pack = OfflinePackViewModel(manager);
    final contextManager = ContextManager(locationService: _NoLocation(), batteryMonitor: _FullBattery());
    questViewModel = QuestViewModel(
      repository,
      contextManager,
      AnalyticsTracker(eventSink: _NullSink(), contextManager: contextManager, sessionId: 'unused'),
      'user-1',
    )..catalog = _catalog;
  });

  Future<void> pumpScreen(WidgetTester tester, {bool offline = false}) async {
    // The app's theme (its buttons are full width) on a small phone, larger text.
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<QuestViewModel>.value(value: questViewModel),
          ChangeNotifierProvider<OfflinePackViewModel>.value(value: pack),
          ChangeNotifierProvider(
            create: (_) => ConnectivityViewModel(connectivity: _FakeConnectivity(offline: offline)),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light, home: const OfflinePackView()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Runs a pack operation for real (SharedPreferences' futures), then redraws.
  Future<void> run(WidgetTester tester, Future<void> Function() action) async {
    await tester.runAsync(action);
    await tester.pumpAndSettle();
  }

  testWidgets('summary, each quest with its emoji and status, and Reintentar when one failed',
      (tester) async {
    repository.savedSteps['ramen'] = _steps('ramen'); // ready
    await tester.runAsync(() async {
      await pack.add('ramen', isOnline: true);
      repository.serverDown = true;
      await pack.add('mural', isOnline: true); // failed
    });
    await pumpScreen(tester);

    expect(find.text('2 quests · 1 ready'), findsOneWidget);
    expect(find.text('🍜'), findsOneWidget);
    expect(find.text('Ramen escondido'), findsOneWidget);
    expect(find.text('Ready to use offline'), findsOneWidget);
    expect(find.text('Download failed'), findsOneWidget);
    expect(find.text(OfflinePackManager.downloadFailedMessage), findsOneWidget);

    repository.serverDown = false;
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await run(tester, () => Future<void>.delayed(Duration.zero));

    expect(find.text('2 quests · 2 ready'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Retry'), findsNothing);
  });

  testWidgets('quitar removes the row and nothing else', (tester) async {
    repository.savedSteps['ramen'] = _steps('ramen');
    await tester.runAsync(() => pack.add('ramen', isOnline: true));
    await pumpScreen(tester);

    await tester.ensureVisible(find.byTooltip('Remove from pack'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove from pack'));
    await run(tester, () => Future<void>.delayed(Duration.zero));

    expect(find.text('Ramen escondido'), findsNothing);
    expect(find.text('0 quests · 0 ready'), findsOneWidget);
    expect(repository.hasCachedSteps('ramen'), isTrue);
  });

  testWidgets('offline: adding leaves it waiting, with the notice; Reintentar disabled',
      (tester) async {
    await pumpScreen(tester, offline: true);

    await tester.ensureVisible(find.text('Add quests'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add quests'));
    await tester.pumpAndSettle();
    // Only the quests not in the pack yet.
    expect(find.text('Ramen escondido'), findsOneWidget);
    expect(find.text('Ruta de murales'), findsOneWidget);
    expect(find.text(OfflineMessages.offlinePackPending), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add').first);
    await run(tester, () => Future<void>.delayed(Duration.zero));
    expect(find.text('Ramen escondido'), findsNothing, reason: 'already in the pack');

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('Waiting for connection'), findsOneWidget);
    expect(find.text('1 quest · 0 ready'), findsOneWidget);
    expect(find.text(OfflineMessages.offlinePackPending), findsOneWidget);
    expect(find.text(OfflineMessages.offlinePackRetry), findsOneWidget);
    final retry = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Retry'));
    expect(retry.onPressed, isNull);
  });
}
