import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/data/remote/network_guard.dart';
import 'package:sidequests/models/group_challenge.dart';
import 'package:sidequests/repository/group_challenge_repository.dart';
import 'package:sidequests/view/social/group_challenges_view.dart';
import 'package:sidequests/view/widgets/offline_notice.dart';
import 'package:sidequests/viewmodel/context/connectivity_view_model.dart';
import 'package:sidequests/viewmodel/social/group_challenges_view_model.dart';

import 'group_challenge_fakes.dart';

void main() {
  late FakeGroupServer server;
  late FakeLocal local;
  late FakeConnectivity connectivity;
  late ConnectivityViewModel connectivityViewModel;

  setUp(() {
    server = FakeGroupServer();
    local = FakeLocal();
    connectivity = FakeConnectivity();
  });

  Future<GroupChallengesViewModel> pumpScreen(WidgetTester tester) async {
    // Tall enough for every section: ListView builds only what's visible.
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    connectivityViewModel = ConnectivityViewModel(connectivity: connectivity);
    addTearDown(connectivityViewModel.dispose);
    await tester.pump();
    final viewModel = GroupChallengesViewModel(
      GroupChallengeRepository(
        server,
        local,
        network: NetworkGuard(isOffline: () async => connectivity.isOffline),
      ),
      FakeQuestRepository(),
      realTracker(FakeAnalyticsSink(), local, connectivity),
      connectivity: connectivityViewModel,
      catalog: () => catalog,
      reconnectDelay: Duration.zero,
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider.value(value: viewModel, child: const GroupChallengesView()),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  ButtonStyleButton button(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(
    find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()).first,
  );

  bool isEnabled(WidgetTester tester, String label) => button(tester, label).onPressed != null;

  testWidgets('online: header, metrics, privacy note, next step and every action on', (tester) async {
    server.seedChallenge('group-photo-walk', owner: userA, ownerProgress: 1);
    server.seedChallenge('park-picnic', owner: userB);

    await pumpScreen(tester);

    expect(find.text('Group challenges'), findsOneWidget);
    expect(find.text('Small adventures, better together.'), findsOneWidget);
    expect(find.text('Challenge joined'), findsOneWidget);
    expect(find.text('Step completed'), findsOneWidget);
    expect(find.textContaining('7 days'), findsOneWidget);
    expect(find.textContaining('self-reported'), findsOneWidget);
    expect(find.textContaining('Only group counts are shared'), findsOneWidget);
    expect(find.text('My challenges'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('1 of 4 steps completed'), findsOneWidget);
    expect(find.text('NEXT STEP · 2'), findsOneWidget);
    expect(find.text('Foto 1'), findsOneWidget);
    expect(find.text('Available challenges'), findsOneWidget);
    expect(find.text('👥 1 participant'), findsNWidgets(2));
    expect(find.text('2 steps'), findsOneWidget);
    expect(find.text('Create a challenge'), findsOneWidget);
    // Already in a Group Photo Walk: only the picnic can be created.
    expect(find.text('Park Picnic'), findsNWidgets(2)); // available + create
    expect(find.byType(OfflineNotice), findsNothing);
    expect(isEnabled(tester, 'Mark next step'), isTrue);
    expect(isEnabled(tester, 'Join'), isTrue);
    expect(isEnabled(tester, 'Create challenge'), isTrue);
  });

  testWidgets('offline: the saved lists with the notice, and create/join/step off', (tester) async {
    server.seedChallenge('group-photo-walk', owner: userA, ownerProgress: 1);
    server.seedChallenge('park-picnic', owner: userB);
    await pumpScreen(tester); // saves both lists
    expect(isEnabled(tester, 'Join'), isTrue);
    server.listCalls.clear();
    connectivity.setOffline(true);

    await pumpScreen(tester);

    expect(find.widgetWithText(OfflineNotice, OfflineMessages.groupChallenges), findsOneWidget);
    expect(OfflineMessages.groupChallenges, 'Previously loaded challenges · connect to make changes.');
    expect(find.text('1 of 4 steps completed'), findsOneWidget);
    expect(isEnabled(tester, 'Mark next step'), isFalse);
    expect(isEnabled(tester, 'Join'), isFalse);
    expect(isEnabled(tester, 'Create challenge'), isFalse);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh)).onPressed, isNull);
    expect(server.listCalls, isEmpty);
  });

  testWidgets('going offline turns the buttons off; back online the lists reload', (tester) async {
    await pumpScreen(tester);
    expect(isEnabled(tester, 'Create challenge'), isTrue);

    connectivity.setOffline(true);
    await tester.pumpAndSettle();
    expect(isEnabled(tester, 'Create challenge'), isFalse);
    expect(find.byType(OfflineNotice), findsOneWidget);

    server.seedChallenge('park-picnic', owner: userB);
    connectivity.setOffline(false);
    await tester.pumpAndSettle();
    expect(find.byType(OfflineNotice), findsNothing);
    expect(isEnabled(tester, 'Join'), isTrue);
  });

  testWidgets('a pending request: the warning and its retry, off while offline', (tester) async {
    local.pendingGroupAction = const GroupAction(
      operation: GroupAction.create,
      requestId: 'pending-1',
      questId: 'group-photo-walk',
      title: 'Group Photo Walk Challenge',
    ).toJson();

    final viewModel = await pumpScreen(tester);

    expect(find.text("We couldn't confirm it was saved. Reconnect and retry: it's safe."), findsOneWidget);
    expect(find.text('Create challenge · Group Photo Walk Challenge'), findsOneWidget);
    expect(isEnabled(tester, 'Retry pending request'), isTrue);
    // Other writes wait for it.
    expect(isEnabled(tester, 'Create challenge'), isFalse);

    connectivity.setOffline(true);
    await tester.pumpAndSettle();
    expect(isEnabled(tester, 'Retry pending request'), isFalse);
    connectivity.setOffline(false);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retry pending request'));
    await tester.pumpAndSettle();

    expect(server.actCalls.single['p_request_id'], 'pending-1');
    expect(viewModel.pending, isNull);
    expect(find.text('Retry pending request'), findsNothing);
    expect(find.text("Challenge created: it's now in My challenges."), findsOneWidget);
    expect(find.text('0 of 4 steps completed'), findsOneWidget);
  });

  testWidgets('empty states, and a list that failed says so', (tester) async {
    server.listError = (mine) => mine ? null : StateError('dropped');

    await pumpScreen(tester);

    expect(find.text("You're not in any challenges yet"), findsOneWidget);
    expect(find.text('List unavailable'), findsOneWidget); // available: never loaded
    expect(find.textContaining('Some lists could not be updated'), findsOneWidget);
    expect(isEnabled(tester, 'Create challenge'), isFalse);

    server.listError = (_) => null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Some lists could not be updated'), findsNothing);
    expect(find.text('No other open challenges'), findsOneWidget);
    expect(isEnabled(tester, 'Create challenge'), isTrue);
  });
}
