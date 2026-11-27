import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../analytics/analytics_event_type.dart';
import '../../analytics/analytics_tracker.dart';
import '../../core/app_exception.dart';
import '../../models/group_challenge.dart';
import '../../models/quest.dart';
import '../../models/quest_step.dart';
import '../../repository/group_challenge_repository.dart';
import '../../repository/quest_repository.dart';
import '../context/connectivity_view_model.dart';

/// How long a connection that came back must hold before the lists reload,
/// so a flapping one doesn't fire a request each time (same wait as
/// ContextStatusViewModel and the bitácora).
const kGroupChallengesReconnectDelay = Duration(seconds: 3);

/// "Crear un reto": the catalogue's group quests, minus the ones the user is
/// already in (the server lists only unexpired memberships). Same rule as
/// Kotlin's creatableGroupQuests.
List<Quest> creatableGroupQuests(List<Quest> catalog, List<GroupChallenge> mine) {
  final joinedQuestIds = {for (final challenge in mine) challenge.questId};
  return catalog.where((quest) => quest.isGroup && !joinedQuestIds.contains(quest.id)).toList();
}

/// The server's `message`, in the app's language. A success always says
/// 'Saved', so what was saved comes from the operation; an unknown text is
/// shown as the server sent it.
String groupActionMessage(GroupAction action, GroupActionResult result) {
  if (result.ok) {
    return switch (action.operation) {
      GroupAction.create => 'Reto creado: ya está en Mis retos.',
      GroupAction.join => 'Te uniste al reto.',
      GroupAction.progress => 'Paso marcado. ¡Sigue así!',
      _ => 'Guardado.',
    };
  }
  return _serverMessagesEs[result.message] ?? result.message;
}

/// Every refusal `group_challenge_act` can answer (migration 011).
const _serverMessagesEs = {
  'Choose an active group quest with steps.': 'Elige una misión en grupo activa y con pasos.',
  'Challenge not found or expired.': 'Este reto ya no existe o venció.',
  'Join this challenge first.': 'Primero únete a este reto.',
  'Progress must be between your current step and the challenge total.':
      'Ese avance no coincide con tu paso actual. Actualiza la lista.',
  'The server could not complete the operation.': 'El servidor no pudo completar la operación.',
};

/// "Retos en grupo" (BQ2, Group Challenge Module): the user's challenges,
/// the ones open to join, and the group quests to start one from. Mirror of
/// Kotlin's GroupChallengesScreen state. Screen-scoped: provided by
/// GroupChallengesView.route(), so every visit starts from fresh data.
///
/// Requests: each create/join/progress gets a new request id here, on the
/// device; only one is in flight at a time. With an answer from the server
/// (applied or refused) its message is shown and the lists reload — the
/// server already logged it, so nothing is tracked. With no answer
/// (dropped connection, timeout) the result is unknown: the request is kept
/// as [pending] (in Hive too) and `group_challenge_client_unconfirmed` is
/// tracked — the only BQ2 event the client sends — and "Reintentar" sends
/// the same request id again, which the server applies at most once. While
/// one is pending the other actions wait, as in Kotlin.
///
/// Eventual connectivity: follows the app-wide [ConnectivityViewModel].
/// Offline it shows the lists saved on the device and blocks every write
/// (server writes are never queued — team rule, docs/OFFLINE_BEHAVIOR.md).
/// Back online, once the connection holds, the lists reload by themselves; a
/// pending request is never resent by itself, only by its button.
class GroupChallengesViewModel extends ChangeNotifier {
  final GroupChallengeRepository _repository;
  final QuestRepository _questRepository;
  final AnalyticsTracker _analytics;
  final ConnectivityViewModel _connectivity;
  final List<Quest> Function() _catalog;
  final String Function() _newRequestId;
  final Duration _reconnectDelay;

  List<GroupChallenge> mine = const [];
  List<GroupChallenge> available = const [];

  /// Each list has a version to show — from the server or saved earlier —
  /// so an empty one means "none", not "unknown".
  bool hasMine = false;
  bool hasAvailable = false;

  /// Both lists came from the server in this visit; writes need it, so a
  /// create never runs against a stale "Mis retos" (Kotlin's `loaded`).
  bool listsFresh = false;

  /// The last reload got only one list (or none): the other shows its last
  /// version.
  bool someListsFailed = false;

  bool isLoading = false;
  bool isSubmitting = false;
  bool isOffline;

  /// The answer to the last request, or why it failed.
  String? message;

  /// The request whose result is unknown, waiting for its retry.
  GroupAction? pending;

  final Map<String, List<QuestStep>> _steps = {};
  Timer? _reconnectTimer;
  bool _disposed = false;

  GroupChallengesViewModel(
    this._repository,
    this._questRepository,
    this._analytics, {
    required ConnectivityViewModel connectivity,
    List<Quest> Function()? catalog,
    String Function()? newRequestId,
    this._reconnectDelay = kGroupChallengesReconnectDelay,
  }) : _connectivity = connectivity,
       _catalog = catalog ?? (() => const []),
       _newRequestId = newRequestId ?? (() => const Uuid().v4()),
       isOffline = connectivity.isOffline {
    // Local storage: what was saved before is on screen from the first frame.
    final saved = _repository.savedLists();
    if (saved.mine != null) {
      mine = saved.mine!;
      hasMine = true;
    }
    if (saved.available != null) {
      available = saved.available!;
      hasAvailable = true;
    }
    pending = _repository.pendingAction();
    _connectivity.addListener(_onConnectivityChanged);
  }

  bool get busy => isLoading || isSubmitting;

  /// Nothing to show yet and the first reload is on its way.
  bool get isFirstLoad => isLoading && !hasMine && !hasAvailable;

  bool get hasSavedLists => hasMine || hasAvailable;

  bool get canRefresh => !isOffline && !busy;

  /// Create, join and "Marcar siguiente paso".
  bool get canWrite => !isOffline && !busy && listsFresh && pending == null;

  bool get canRetryPending => pending != null && !isOffline && !busy;

  int get joinedCount => mine.length;

  int get completedSteps => mine.fold(0, (sum, challenge) => sum + challenge.progress);

  List<Quest> get creatableQuests => creatableGroupQuests(_catalog(), mine);

  Quest? questFor(String questId) => _catalog().where((quest) => quest.id == questId).firstOrNull;

  /// The step after the ones done, from the quest's `quest_steps`; null when
  /// the challenge is complete or its steps aren't on the device.
  QuestStep? nextStepFor(GroupChallenge challenge) {
    final steps = _steps[challenge.questId];
    if (steps == null || challenge.progress >= steps.length) return null;
    return steps[challenge.progress];
  }

  /// Called once the screen is up. Steps of the saved challenges first (they
  /// may be on the device), then the lists from the server.
  Future<void> load() async {
    unawaited(_loadSteps());
    await refresh();
  }

  Future<void> refresh() async {
    if (!canRefresh || _disposed) return;
    message = null;
    await _reloadLists();
  }

  Future<void> createChallenge(Quest quest) => _start(
    GroupAction(
      operation: GroupAction.create,
      requestId: _newRequestId(),
      questId: quest.id,
      title: quest.title,
    ),
  );

  Future<void> joinChallenge(GroupChallenge challenge) => _start(
    GroupAction(
      operation: GroupAction.join,
      requestId: _newRequestId(),
      challengeId: challenge.challengeId,
      title: challenge.title,
    ),
  );

  Future<void> markNextStep(GroupChallenge challenge) async {
    if (challenge.isCompleted) return;
    await _start(
      GroupAction(
        operation: GroupAction.progress,
        requestId: _newRequestId(),
        challengeId: challenge.challengeId,
        progressValue: challenge.progress + 1,
        title: challenge.title,
      ),
    );
  }

  /// Sends [pending] again, same request id and all: if the first try did
  /// arrive, the server answers what it answered then.
  Future<void> retryPending() async {
    final action = pending;
    if (action == null || !canRetryPending) return;
    await _send(action);
  }

  Future<void> _start(GroupAction action) async {
    if (!canWrite) return;
    await _send(action);
  }

  Future<void> _send(GroupAction action) async {
    if (_disposed) return;
    isSubmitting = true;
    message = null;
    _notify();
    try {
      final result = await _repository.act(action);
      await _setPending(null);
      message = groupActionMessage(action, result);
      await _reloadLists();
    } on GroupActionUnconfirmedException {
      _trackUnconfirmed(action);
      await _setPending(action);
    } on GroupActionNotSentException catch (e) {
      // Never left the phone. A retry of a pending one stays pending: the
      // first try is still unknown.
      message = e.message;
    } on AppException catch (e) {
      // PostgREST answered with an error: the request was refused, not lost.
      await _setPending(null);
      message = e.message;
      await _reloadLists();
    } finally {
      isSubmitting = false;
      _notify();
    }
  }

  /// BQ2's client side: a request that may have reached the server but whose
  /// answer never came back. The pipeline matches its request id against the
  /// server's log. Offline, AnalyticsTracker queues it and sends it later.
  /// No coordinates: the question is about the request, not the place.
  void _trackUnconfirmed(GroupAction action) {
    unawaited(
      _analytics.trackDetailed(
        AnalyticsEventType.groupChallengeClientUnconfirmed,
        metadataForDistance: (_) => {'operation': action.operation, 'request_id': action.requestId},
        withCoordinates: false,
      ),
    );
  }

  Future<void> _setPending(GroupAction? action) async {
    pending = action;
    await _repository.savePendingAction(action);
  }

  Future<void> _reloadLists() async {
    if (_disposed) return;
    isLoading = true;
    _notify();
    final lists = await _repository.loadLists();
    if (_disposed) return;
    final mineResult = lists.mine;
    final availableResult = lists.available;
    if (mineResult.isSuccess) {
      mine = mineResult.challenges!;
      hasMine = true;
    }
    if (availableResult.isSuccess) {
      available = availableResult.challenges!;
      hasAvailable = true;
    }
    listsFresh = mineResult.isSuccess && availableResult.isSuccess;
    someListsFailed = !listsFresh;
    isLoading = false;
    _notify();
    unawaited(_loadSteps());
  }

  /// The steps of every challenge in "Mis retos" not loaded yet, in parallel.
  /// QuestRepository answers from memory or Hive when it can; a quest whose
  /// steps can't be had just shows no "Siguiente paso" (tried again next
  /// reload).
  Future<void> _loadSteps() async {
    final questIds = {for (final challenge in mine) challenge.questId}..removeAll(_steps.keys);
    if (questIds.isEmpty) return;
    var loadedAny = false;
    await Future.wait(
      questIds.map((questId) async {
        try {
          _steps[questId] = await _questRepository.getSteps(questId);
          loadedAny = true;
        } catch (_) {}
      }),
    );
    if (loadedAny) _notify();
  }

  void _onConnectivityChanged() {
    final offline = _connectivity.isOffline;
    if (_disposed || offline == isOffline) return;
    isOffline = offline;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (!offline) {
      _reconnectTimer = Timer(_reconnectDelay, () {
        _reconnectTimer = null;
        unawaited(refresh());
      });
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _connectivity.removeListener(_onConnectivityChanged);
    super.dispose();
  }
}
