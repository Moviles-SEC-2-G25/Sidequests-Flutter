import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sidequests/view/widgets/context_banner.dart';
import 'package:sidequests/viewmodel/context/context_status_view_model.dart';

const _offline = [ConnectivityResult.none];
const _wifi = [ConnectivityResult.wifi];
const _reconnectDelay = Duration(milliseconds: 20);

class _FakeConnectivity implements Connectivity {
  List<ConnectivityResult> current;
  final changes = StreamController<List<ConnectivityResult>>.broadcast();

  _FakeConnectivity(this.current);

  void set(List<ConnectivityResult> results) {
    current = results;
    changes.add(results);
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBattery implements Battery {
  final int level;

  _FakeBattery(this.level);

  @override
  Future<int> get batteryLevel async => level;

  @override
  Stream<BatteryState> get onBatteryStateChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

Future<void> _waitOutReconnectDelay() => Future<void>.delayed(_reconnectDelay * 2);

void main() {
  late _FakeConnectivity connectivity;
  late int refreshes;

  ContextStatusViewModel viewModel({int batteryLevel = 80}) => ContextStatusViewModel(
    onReconnected: () => refreshes++,
    reconnectDelay: _reconnectDelay,
    connectivity: connectivity,
    battery: _FakeBattery(batteryLevel),
  );

  setUp(() {
    connectivity = _FakeConnectivity(_offline);
    refreshes = 0;
  });

  test('back online: announced at once, one refresh once the connection held', () async {
    final status = viewModel();
    addTearDown(status.dispose);
    await _settle();
    expect(status.isOffline, isTrue);

    connectivity.set(_wifi);
    await _settle();
    expect(status.isOffline, isFalse);
    expect(status.justReconnected, isTrue);
    expect(refreshes, 0);

    await _waitOutReconnectDelay();
    expect(refreshes, 1);
    expect(status.justReconnected, isFalse);
  });

  test('a connection that drops again within the delay never refreshes', () async {
    final status = viewModel();
    addTearDown(status.dispose);
    await _settle();

    connectivity.set(_wifi);
    await _settle();
    connectivity.set(_offline);
    await _waitOutReconnectDelay();

    expect(refreshes, 0);
    expect(status.isOffline, isTrue);
    expect(status.justReconnected, isFalse);
  });

  test('starting online is not a reconnection', () async {
    connectivity = _FakeConnectivity(_wifi);
    final status = viewModel();
    addTearDown(status.dispose);

    await _waitOutReconnectDelay();

    expect(refreshes, 0);
    expect(status.justReconnected, isFalse);
  });

  test('repeated "online" events (Wi-Fi, then Wi-Fi + mobile) refresh once', () async {
    final status = viewModel();
    addTearDown(status.dispose);
    await _settle();

    connectivity.set(_wifi);
    await _settle();
    connectivity.set([ConnectivityResult.wifi, ConnectivityResult.mobile]);
    await _waitOutReconnectDelay();

    expect(refreshes, 1);
  });

  testWidgets('banner: offline first, then "Conexión restablecida", then low battery', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => viewModel(batteryLevel: 10),
        child: const MaterialApp(home: Scaffold(body: ContextBanner())),
      ),
    );
    await tester.pump(); // connectivity + battery read
    expect(find.textContaining('Sin conexión'), findsOneWidget);

    connectivity.set(_wifi);
    await tester.pump(Duration.zero); // deliver the event, then rebuild
    expect(find.textContaining('Conexión restablecida'), findsOneWidget);

    await tester.pump(_reconnectDelay * 2);
    expect(find.textContaining('Batería baja'), findsOneWidget);
    expect(refreshes, 1);
  });
}
