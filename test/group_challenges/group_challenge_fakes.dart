import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidequests/analytics/analytics_event_sink.dart';
import 'package:sidequests/analytics/analytics_tracker.dart';
import 'package:sidequests/data/context/context_manager.dart';
import 'package:sidequests/data/local/local_data_source.dart';
import 'package:sidequests/data/remote/supabase_remote_data_source.dart';
import 'package:sidequests/data/services/battery_monitor.dart';
import 'package:sidequests/data/services/location_service.dart';
import 'package:sidequests/data/services/weather_service.dart';
import 'package:sidequests/models/quest.dart';
import 'package:sidequests/models/quest_step.dart';
import 'package:sidequests/repository/quest_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const userA = 'user-a';
const userB = 'user-b';

/// What a request does to the connection.
enum Transport {
  ok,

  /// Dropped before reaching the server: nothing applied.
  dropBeforeServer,

  /// Applied and logged by the server, but the answer never came back.
  dropAfterServer,
}

class _Challenge {
  final String id;
  final String questId;
  final String title;
  final int totalSteps;
  final Map<String, int> progress = {};

  _Challenge(this.id, this.questId, this.title, this.totalSteps);
}

/// Migration 011 in memory: `group_challenge_list` / `group_challenge_act`
/// with the same rules — idempotent per (user, request id), every request it
/// receives logged in [operations] — as the data source the repository
/// calls. [userId] is whoever is signed in, so two accounts can share it.
class FakeGroupServer implements SupabaseRemoteDataSource {
  String userId = userA;

  /// Active group quests and their step count.
  final Map<String, ({String title, int steps})> groupQuests = {
    'group-photo-walk': (title: 'Group Photo Walk Challenge', steps: 4),
    'park-picnic': (title: 'Park Picnic', steps: 2),
  };

  final Map<String, _Challenge> _challenges = {};

  /// sidequests_group_private.operations: (user, request id) → saved answer.
  final Map<(String, String), Map<String, dynamic>> operations = {};

  /// Every act request that left the phone, in order.
  final List<Map<String, Object?>> actCalls = [];

  /// Every list request that left the phone: true = mine.
  final List<bool> listCalls = [];

  Transport actTransport = Transport.ok;

  /// Thrown instead of answering the list(s) it names.
  Object? Function(bool mine) listError = (_) => null;

  /// Holds the list answers back until completed (null: answer right away).
  Completer<void>? listGate;

  /// Holds the act answer back until completed.
  Completer<void>? actGate;

  /// PostgREST answering with an error instead of running the function.
  PostgrestException? actRejection;

  int _nextId = 1;

  @override
  Future<List<Map<String, dynamic>>> groupChallengeList({required bool mine}) async {
    listCalls.add(mine);
    await listGate?.future;
    final error = listError(mine);
    if (error != null) throw error;
    return [
      for (final c in _challenges.values.toList().reversed)
        if (c.progress.containsKey(userId) == mine)
          {
            'challenge_id': c.id,
            'quest_id': c.questId,
            'title': c.title,
            'participants': c.progress.length,
            'my_progress': c.progress[userId],
            'total_steps': c.totalSteps,
            'completed_participants': c.progress.values.where((p) => p == c.totalSteps).length,
          },
    ];
  }

  @override
  Future<Map<String, dynamic>> groupChallengeAct({
    required String action,
    required String requestId,
    String? challengeId,
    String? questId,
    int? progress,
  }) async {
    actCalls.add({
      'p_action': action,
      'p_request_id': requestId,
      'p_challenge_id': challengeId,
      'p_quest_id': questId,
      'p_progress': progress,
    });
    await actGate?.future;
    if (actTransport == Transport.dropBeforeServer) throw const SocketException('connection reset');
    if (actRejection != null) throw actRejection!;
    final outcome = operations[(userId, requestId)] ??= _apply(
      action,
      challengeId: challengeId,
      questId: questId,
      progress: progress,
    );
    if (actTransport == Transport.dropAfterServer) throw http.ClientException('connection closed');
    return {...outcome};
  }

  Map<String, dynamic> _apply(String action, {String? challengeId, String? questId, int? progress}) {
    String? failure;
    String? id = challengeId;
    if (action == 'create') {
      final quest = groupQuests[questId];
      if (quest == null) {
        failure = 'Choose an active group quest with steps.';
        id = null;
      } else {
        id = 'challenge-${_nextId++}';
        _challenges[id] = _Challenge(id, questId!, quest.title, quest.steps)..progress[userId] = 0;
      }
    } else {
      final challenge = _challenges[challengeId];
      if (challenge == null) {
        failure = 'Challenge not found or expired.';
        id = null;
      } else if (action == 'join') {
        challenge.progress.putIfAbsent(userId, () => 0);
      } else {
        final current = challenge.progress[userId];
        if (current == null) {
          failure = 'Join this challenge first.';
        } else if (progress == null || progress < current || progress > challenge.totalSteps) {
          failure = 'Progress must be between your current step and the challenge total.';
        } else {
          challenge.progress[userId] = progress;
        }
      }
    }
    return {'ok': failure == null, 'message': failure ?? 'Saved', 'challenge_id': id};
  }

  /// A challenge created by [owner] straight on the server.
  String seedChallenge(String questId, {required String owner, int ownerProgress = 0}) {
    final quest = groupQuests[questId]!;
    final id = 'challenge-${_nextId++}';
    _challenges[id] = _Challenge(id, questId, quest.title, quest.steps)..progress[owner] = ownerProgress;
    return id;
  }

  int? progressOf(String challengeId, String user) => _challenges[challengeId]?.progress[user];

  int membersOf(String challengeId) => _challenges[challengeId]?.progress.length ?? 0;

  @override
  Future<void> signOut() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Hive box, in memory: group lists, the pending request and the
/// analytics queue.
class FakeLocal implements LocalDataSource {
  final Map<bool, List<Map<String, dynamic>>> groupLists = {};
  Map<String, dynamic>? pendingGroupAction;
  List<Map<String, dynamic>> pendingAnalytics = [];

  @override
  List<Map<String, dynamic>>? getGroupChallenges({required bool mine}) =>
      groupLists[mine]?.map((row) => {...row}).toList();

  @override
  Future<void> cacheGroupChallenges({
    required bool mine,
    required List<Map<String, dynamic>> rows,
  }) async => groupLists[mine] = rows;

  @override
  Map<String, dynamic>? getPendingGroupAction() =>
      pendingGroupAction == null ? null : {...pendingGroupAction!};

  @override
  Future<void> savePendingGroupAction(Map<String, dynamic>? action) async =>
      pendingGroupAction = action;

  @override
  List<Map<String, dynamic>> getPendingAnalyticsEvents() => [...pendingAnalytics];

  @override
  Future<void> savePendingAnalyticsEvents(List<Map<String, dynamic>> events) async =>
      pendingAnalytics = events;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Steps per quest, as QuestRepository.getSteps returns them.
class FakeQuestRepository implements QuestRepository {
  final Map<String, List<QuestStep>> steps = {
    'group-photo-walk': [
      for (var i = 0; i < 4; i++)
        QuestStep(
          id: i + 1,
          questId: 'group-photo-walk',
          stepOrder: i,
          title: 'Foto $i',
          description: 'Descripción $i',
        ),
    ],
  };

  @override
  Future<List<QuestStep>> getSteps(String questId) async =>
      steps[questId] ?? (throw Exception('no steps saved'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `public.analytics_events`: [offline] fails like a dropped connection.
class FakeAnalyticsSink implements AnalyticsEventSink {
  bool offline = false;
  final List<Map<String, dynamic>> inserted = [];

  @override
  Future<void> insertAnalyticsEvent(Map<String, dynamic> event) async {
    if (offline) throw const SocketException('offline');
    inserted.add(event);
  }
}

/// connectivity_plus, switchable from the test.
class FakeConnectivity implements Connectivity {
  List<ConnectivityResult> current;
  final _changes = StreamController<List<ConnectivityResult>>.broadcast();

  FakeConnectivity({bool offline = false})
    : current = [offline ? ConnectivityResult.none : ConnectivityResult.wifi];

  bool get isOffline => current.contains(ConnectivityResult.none);

  void setOffline(bool offline) {
    current = [offline ? ConnectivityResult.none : ConnectivityResult.wifi];
    _changes.add(current);
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => current;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;

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

/// The real tracker over [sink], queueing in [local] when the sink is down.
AnalyticsTracker realTracker(FakeAnalyticsSink sink, FakeLocal local, FakeConnectivity connectivity) =>
    AnalyticsTracker(
      eventSink: sink,
      contextManager: ContextManager(
        locationService: _NoLocation(),
        batteryMonitor: _FullBattery(),
        connectivity: connectivity,
        weatherService: WeatherService(client: MockClient((_) async => http.Response('', 503))),
      ),
      sessionId: '7f1c0c4e-0000-4000-8000-000000000000',
      localDataSource: local,
    );

const groupPhotoWalk = Quest(
  id: 'group-photo-walk',
  title: 'Group Photo Walk Challenge',
  category: 'Art',
  emoji: '📸',
  durationMinutes: 45,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'group',
  isGroup: true,
);

const parkPicnic = Quest(
  id: 'park-picnic',
  title: 'Park Picnic',
  category: 'Food',
  emoji: '🧺',
  durationMinutes: 60,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'group',
  isGroup: true,
);

const soloRamen = Quest(
  id: 'ramen-spot',
  title: 'Try the New Ramen Spot',
  category: 'Food',
  durationMinutes: 30,
  difficulty: 'easy',
  locationMode: 'gps',
  socialLevel: 'solo',
);

const catalog = [groupPhotoWalk, parkPicnic, soloRamen];
