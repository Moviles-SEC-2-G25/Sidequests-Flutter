import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/core/mission_history.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/models/user_quest.dart';
import 'package:sidequests/repository/evidence_repository.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:sidequests/view/profile/attempt_evidence_view.dart';
import 'package:sidequests/view/profile/mission_history_view.dart';
import 'package:sidequests/view/widgets/offline_notice.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';
import 'package:sidequests/viewmodel/profile/attempt_evidence_view_model.dart';
import 'package:sidequests/viewmodel/profile/mission_history_view_model.dart';

import '../helpers/evidence_fakes.dart';

final _attempt = EvidenceAttempt(
  attemptId: 'attempt-1',
  questId: 'quest-1',
  questTitle: 'Ramen escondido',
  date: DateTime(2026, 11, 20),
);

/// Only what MissionHistoryViewModel reads (like the bitácora's own tests).
class _HistoryRepository implements QuestRepository {
  @override
  Future<List<Quest>> getCatalog() async => [
    const Quest(
      id: 'quest-1',
      title: 'Ramen escondido',
      category: 'food',
      durationMinutes: 40,
      difficulty: 'easy',
      locationMode: 'specific',
      socialLevel: 'solo',
    ),
  ];

  @override
  Future<({List<UserQuest> userQuests, bool fromCache})> getUserQuestsWithSource(String userId) async => (
    userQuests: [
      UserQuest(
        id: 'attempt-1',
        userId: 'u',
        questId: 'quest-1',
        status: 'completed',
        acceptedAt: DateTime(2026, 11, 20, 9),
        completedAt: DateTime(2026, 11, 20, 10),
        rating: 5,
      ),
    ],
    fromCache: false,
  );

  @override
  Set<String> pendingSyncAttemptIds() => const {};

  @override
  Map<String, int> getStepTotals() => const {};

  @override
  DateTime? userQuestsSyncedAt() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeEvidenceRemote remote;
  late FakeEvidenceQuestRepository quests;
  late FakeEvidenceLocal local;
  late MemoryEvidenceStore store;
  late FakeConnectivity connectivity;
  late EvidenceRepository repository;

  setUp(() {
    remote = FakeEvidenceRemote();
    quests = FakeEvidenceQuestRepository()
      ..steps = const [
        QuestStep(id: 1, questId: 'quest-1', stepOrder: 0, title: 'Encuentra el local'),
        QuestStep(id: 2, questId: 'quest-1', stepOrder: 1, title: 'Foto del plato'),
      ];
    local = FakeEvidenceLocal();
    store = MemoryEvidenceStore();
    connectivity = FakeConnectivity();
    repository = EvidenceRepository(
      quests,
      remote,
      local,
      store: store,
      network: NetworkGuard(isOffline: () async => connectivity.isOffline),
      // The photo is its own thumbnail: real JPEG bytes, no isolate.
      makeThumbnail: (jpeg) async => jpeg,
      log: (_) {},
    );
    final proofs = [
      proofOf('p0', stepOrder: 0),
      proofOf('p1', stepOrder: 1, uploadedAt: DateTime(2026, 11, 20, 11)),
      proofOf('p2', stepOrder: 1, uploadedAt: DateTime(2026, 11, 20, 10)),
    ];
    for (final (i, proof) in proofs.indexed) {
      remote.addProof(proof, testJpeg(8, 6, seed: i));
    }
    quests.serverProofs['attempt-1'] = proofs;
  });

  Widget app({required Widget Function() home}) => MultiProvider(
    providers: [
      Provider<EvidenceRepository>.value(value: repository),
      ChangeNotifierProvider<ConnectivityViewModel>.value(value: connectivity),
    ],
    child: MaterialApp(home: Builder(builder: (_) => home())),
  );

  /// The evidence route, pushed over an empty screen, on a small phone.
  Future<void> openEvidence(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        home: () => Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(AttemptEvidenceView.route(_attempt)),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pump(); // the route
    await tester.pump(const Duration(milliseconds: 400)); // transition + load
    await tester.pump(const Duration(milliseconds: 50)); // thumbnails
  }

  testWidgets('groups the photos by step, titled with the mission and the date', (tester) async {
    await openEvidence(tester);

    expect(find.text('Ramen escondido'), findsOneWidget);
    expect(find.text('Attempt on November 20, 2026'), findsOneWidget);
    expect(find.text('Step 1: Encuentra el local'), findsOneWidget);
    expect(find.text('Step 2: Foto del plato'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Step 2: Foto del plato, photo 2')), findsOneWidget);
    // Shown with network = saved on the phone.
    expect(find.byTooltip('Saved on phone'), findsNWidgets(3));
    expect(find.text('3 of 3 photos saved on the phone'), findsOneWidget);
    expect(find.text('All saved on phone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tile opens the full-screen viewer (zoom) on that photo; swiping goes to the next', (tester) async {
    await openEvidence(tester);

    await tester.tap(find.bySemanticsLabel(RegExp(r'^Step 2: Foto del plato, photo 1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.text('Step 2: Foto del plato'), findsWidgets);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('3 of 3'), findsOneWidget);
  });

  testWidgets('offline: the team\'s notice, "Available when back online", pending photos, and no "Guardar todas"', (
    tester,
  ) async {
    await repository.getPhotoProofs('attempt-1'); // listed online once
    quests.listOffline = true;
    connectivity.isOffline = true;
    final pending = pendingOf('taken-offline', stepOrder: 0);
    quests.pending = [pending];
    local.pendingFiles[pending.localPath] = testJpeg(8, 6, seed: 9);

    await openEvidence(tester);

    expect(find.byType(OfflineNotice), findsOneWidget);
    expect(find.text(OfflineMessages.attemptEvidence), findsOneWidget);
    expect(find.text('Available when back online'), findsNWidgets(3));
    expect(find.text('Waiting to upload'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'no spinner waiting on no network');
    final saveAll = tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text('Save all to phone'), matching: find.bySubtype<ButtonStyleButton>()),
    );
    expect(saveAll.onPressed, isNull);
    expect(remote.downloads, isEmpty);
  });

  testWidgets('an attempt without photos says so', (tester) async {
    quests.serverProofs['attempt-1'] = [];
    await openEvidence(tester);
    expect(find.text('This attempt has no photos'), findsOneWidget);
  });

  testWidgets('Mi bitácora: the "Evidence" button of a card opens this attempt\'s evidence', (tester) async {
    tester.view.physicalSize = const Size(360, 690);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        home: () => ChangeNotifierProvider(
          create: (_) => MissionHistoryViewModel(
            _HistoryRepository(),
            'u',
            runner: (input) async => buildMissionHistory(input),
            isOffline: () async => false,
            offlineChanges: () => const Stream.empty(),
          ),
          child: const MissionHistoryView(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Ramen escondido'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Evidence'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final view = tester.widget<AttemptEvidenceView>(find.byType(AttemptEvidenceView));
    expect(view.attempt.attemptId, 'attempt-1');
    expect(view.attempt.questId, 'quest-1');
    expect(quests.listReads, 1, reason: 'the list of that attempt was asked for');
    expect(find.text('Attempt on November 20, 2026'), findsOneWidget);
  });
}
