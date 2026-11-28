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

    expect(find.text('Retos en grupo'), findsOneWidget);
    expect(find.text('Pequeñas aventuras, mejor en compañía.'), findsOneWidget);
    expect(find.text('Reto unido'), findsOneWidget);
    expect(find.text('Paso completado'), findsOneWidget);
    expect(find.textContaining('7 días'), findsOneWidget);
    expect(find.textContaining('auto-reportados'), findsOneWidget);
    expect(find.textContaining('Solo se comparten conteos'), findsOneWidget);
    expect(find.text('Mis retos'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('1 de 4 pasos completados'), findsOneWidget);
    expect(find.text('SIGUIENTE PASO · 2'), findsOneWidget);
    expect(find.text('Foto 1'), findsOneWidget);
    expect(find.text('Retos disponibles'), findsOneWidget);
    expect(find.text('👥 1 participante'), findsNWidgets(2));
    expect(find.text('2 pasos'), findsOneWidget);
    expect(find.text('Crear un reto'), findsOneWidget);
    // Already in a Group Photo Walk: only the picnic can be created.
    expect(find.text('Park Picnic'), findsNWidgets(2)); // available + create
    expect(find.byType(OfflineNotice), findsNothing);
    expect(isEnabled(tester, 'Marcar siguiente paso'), isTrue);
    expect(isEnabled(tester, 'Unirme'), isTrue);
    expect(isEnabled(tester, 'Crear reto'), isTrue);
  });

  testWidgets('offline: the saved lists with the notice, and create/join/step off', (tester) async {
    server.seedChallenge('group-photo-walk', owner: userA, ownerProgress: 1);
    server.seedChallenge('park-picnic', owner: userB);
    await pumpScreen(tester); // saves both lists
    expect(isEnabled(tester, 'Unirme'), isTrue);
    server.listCalls.clear();
    connectivity.setOffline(true);

    await pumpScreen(tester);

    expect(find.widgetWithText(OfflineNotice, OfflineMessages.groupChallenges), findsOneWidget);
    expect(OfflineMessages.groupChallenges, 'Retos cargados antes · conéctate para hacer cambios.');
    expect(find.text('1 de 4 pasos completados'), findsOneWidget);
    expect(isEnabled(tester, 'Marcar siguiente paso'), isFalse);
    expect(isEnabled(tester, 'Unirme'), isFalse);
    expect(isEnabled(tester, 'Crear reto'), isFalse);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh)).onPressed, isNull);
    expect(server.listCalls, isEmpty);
  });

  testWidgets('going offline turns the buttons off; back online the lists reload', (tester) async {
    await pumpScreen(tester);
    expect(isEnabled(tester, 'Crear reto'), isTrue);

    connectivity.setOffline(true);
    await tester.pumpAndSettle();
    expect(isEnabled(tester, 'Crear reto'), isFalse);
    expect(find.byType(OfflineNotice), findsOneWidget);

    server.seedChallenge('park-picnic', owner: userB);
    connectivity.setOffline(false);
    await tester.pumpAndSettle();
    expect(find.byType(OfflineNotice), findsNothing);
    expect(isEnabled(tester, 'Unirme'), isTrue);
  });

  testWidgets('a pending request: the warning and its retry, off while offline', (tester) async {
    local.pendingGroupAction = const GroupAction(
      operation: GroupAction.create,
      requestId: 'pending-1',
      questId: 'group-photo-walk',
      title: 'Group Photo Walk Challenge',
    ).toJson();

    final viewModel = await pumpScreen(tester);

    expect(find.text('No sabemos si se guardó. Reconecta y reintenta: es seguro.'), findsOneWidget);
    expect(find.text('Crear reto · Group Photo Walk Challenge'), findsOneWidget);
    expect(isEnabled(tester, 'Reintentar solicitud pendiente'), isTrue);
    // Other writes wait for it.
    expect(isEnabled(tester, 'Crear reto'), isFalse);

    connectivity.setOffline(true);
    await tester.pumpAndSettle();
    expect(isEnabled(tester, 'Reintentar solicitud pendiente'), isFalse);
    connectivity.setOffline(false);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reintentar solicitud pendiente'));
    await tester.pumpAndSettle();

    expect(server.actCalls.single['p_request_id'], 'pending-1');
    expect(viewModel.pending, isNull);
    expect(find.text('Reintentar solicitud pendiente'), findsNothing);
    expect(find.text('Reto creado: ya está en Mis retos.'), findsOneWidget);
    expect(find.text('0 de 4 pasos completados'), findsOneWidget);
  });

  testWidgets('empty states, and a list that failed says so', (tester) async {
    server.listError = (mine) => mine ? null : StateError('dropped');

    await pumpScreen(tester);

    expect(find.text('Aún no estás en ningún reto'), findsOneWidget);
    expect(find.text('Lista no disponible'), findsOneWidget); // available: never loaded
    expect(find.textContaining('Algunas listas no se pudieron actualizar'), findsOneWidget);
    expect(isEnabled(tester, 'Crear reto'), isFalse);

    server.listError = (_) => null;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Algunas listas no se pudieron actualizar'), findsNothing);
    expect(find.text('No hay otros retos abiertos'), findsOneWidget);
    expect(isEnabled(tester, 'Crear reto'), isTrue);
  });
}
