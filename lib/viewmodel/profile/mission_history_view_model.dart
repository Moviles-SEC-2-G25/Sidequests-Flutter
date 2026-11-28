import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../../core/app_exception.dart';
import '../../core/mission_history.dart';
import '../../data/cache/memory_cache.dart';
import '../../models/quest.dart';
import '../../models/user_quest.dart';
import '../../repository/quest_repository.dart';

enum HistoryStatus { loading, error, empty, data }

/// What the bitácora says about where its data comes from, if anything.
enum HistoryConnectionNotice {
  /// The device has no network: the saved copy is shown, and it refreshes on
  /// its own when the connection is back.
  offline,

  /// Back online (or a retry): the saved copy is on screen while the queued
  /// changes go out and fresh data comes in.
  syncing,

  /// The device says it's online, but the server didn't answer (Wi-Fi without
  /// internet, server down): the saved copy is shown.
  serverUnreachable,
}

/// How [buildMissionHistory] gets run. Injectable because a real isolate
/// never finishes inside testWidgets' fake async zone (same as StatsRunner).
typedef MissionHistoryRunner = Future<MissionHistory> Function(MissionHistoryInput input);

/// Multithreading strategy: joining every attempt with the catalogue,
/// normalizing text for the search, filtering, sorting and grouping by month
/// is CPU work that grows with the history (attempts are never deleted) and
/// runs again on every filter tap and every pause while typing — right while
/// the keyboard animates. compute() moves it to a background isolate, so the
/// UI thread only paints; on the web build it runs inline. Kotlin:
/// withContext(Dispatchers.Default).
Future<MissionHistory> _buildInBackground(MissionHistoryInput input) => compute(buildMissionHistory, input);

/// Pause in the typing before the search runs: one background run per pause,
/// not one per key.
const kHistorySearchDebounce = Duration(milliseconds: 300);

/// How long a connection that came back must hold before the bitácora
/// refreshes, so a flapping one doesn't fire a request each time — the same
/// wait as ContextStatusViewModel's reconnect.
const kHistoryReconnectDelay = Duration(seconds: 3);

/// Filter + search combinations kept computed: the three filters and a few
/// searches. LRU past it, so a long session of searching stays bounded.
const kHistoryCacheMaxEntries = 10;

/// Only a ceiling MemoryCache asks for: what really invalidates an entry is
/// new data (every load() empties the cache), not time.
const kHistoryCacheTtl = Duration(minutes: 10);

/// What makes two runs of [buildMissionHistory] give the same answer over the
/// same data: the filter and the search as it's compared ("Café " = "cafe").
typedef _HistoryCacheKey = (HistoryFilter, String);

/// "Mi bitácora": every attempt (completed, abandoned, in progress) grouped
/// by month, with a filter and a search. Screen-scoped — provided by
/// MissionHistoryView.route(), like StatsViewModel — so every visit starts
/// from fresh data and nothing outlives the screen.
///
/// Eventual connectivity: everything it shows comes from the device once
/// loaded, so the search and the filters keep working without a connection.
/// It follows the connection while open — saying when the device goes
/// offline, and refreshing on its own once the connection is back and holds:
/// the changes made offline are sent first, then fresh data replaces the
/// saved copy. Kotlin: a ConnectivityManager callback as a Flow, with
/// collectLatest { delay(3 s); load() }.
///
/// Caching: the history computed in the background for a filter + search is
/// kept in memory ([MemoryCache], LRU), so going back to one already seen
/// (a chip tapped again, the search cleared) is instant and spawns no
/// isolate. It's only valid for the data it was computed from, so every
/// load() — pull to refresh, the refresh after reconnecting — empties it.
/// Kotlin: an LruCache in the ViewModel, cleared in load().
///
/// Local storage: [lastSyncedAt], when the attempts were last read from the
/// server, comes from Hive (QuestRepository.userQuestsSyncedAt), so even
/// after a restart offline the banner says how old the saved copy is.
class MissionHistoryViewModel extends ChangeNotifier {
  final QuestRepository _questRepository;
  final String _userId;
  final MissionHistoryRunner _runner;
  final Duration _searchDebounce;
  final Duration _reconnectDelay;
  final Future<bool> Function() _isOffline;
  final Stream<bool> Function() _offlineChanges;
  final _historyCache = MemoryCache<_HistoryCacheKey, MissionHistory>(
    ttl: kHistoryCacheTtl,
    maxEntries: kHistoryCacheMaxEntries,
  );

  /// Starts as loading so the very first frame already shows the spinner.
  HistoryStatus status = HistoryStatus.loading;
  String? errorMessage;

  /// True when the attempts are the Hive cache (offline) — the view says so.
  bool isFromCache = false;

  /// The device has no network right now. Unknown counts as online: requests
  /// still have their own timeouts.
  bool isOffline = false;

  /// A reload is out while a list is on screen (pull to refresh, or the
  /// refresh after reconnecting).
  bool isRefreshing = false;

  /// When the attempts were last read from the server, saved on the device;
  /// null if never. The banner shows it while the list isn't fresh.
  DateTime? lastSyncedAt;

  HistoryFilter filter = HistoryFilter.all;
  String query = '';
  MissionHistory history = MissionHistory.empty;

  /// A background run for the current filter/search hasn't answered yet.
  bool isUpdating = false;

  List<Quest> _catalog = const [];
  List<UserQuest> _userQuests = const [];
  Map<String, int> _stepTotals = const {};
  Set<String> _pendingSyncIds = const {};

  /// Bumped on every run: an answer whose number is no longer the latest
  /// was overtaken by a newer filter/search, and is dropped. Kotlin gets the
  /// same by cancelling the previous Job (or mapLatest).
  int _generation = 0;
  Timer? _searchTimer;
  Timer? _reconnectTimer;
  StreamSubscription<bool>? _connectivitySubscription;
  Future<void>? _loadInFlight;
  bool _isDisposed = false;

  MissionHistoryViewModel(
    this._questRepository,
    this._userId, {
    MissionHistoryRunner? runner,
    Duration? searchDebounce,
    Duration? reconnectDelay,
    Future<bool> Function()? isOffline,
    Stream<bool> Function()? offlineChanges,
  }) : _runner = runner ?? _buildInBackground,
       _searchDebounce = searchDebounce ?? kHistorySearchDebounce,
       _reconnectDelay = reconnectDelay ?? kHistoryReconnectDelay,
       _isOffline = isOffline ?? _connectivityIsOffline,
       _offlineChanges = offlineChanges ?? _connectivityOfflineChanges {
    _watchConnectivity();
  }

  static Future<bool> _connectivityIsOffline() async =>
      (await Connectivity().checkConnectivity()).contains(ConnectivityResult.none);

  static Stream<bool> _connectivityOfflineChanges() => Connectivity().onConnectivityChanged.map(
    (results) => results.contains(ConnectivityResult.none),
  );

  /// Filtered or searched: the view then says how many of the total it shows.
  bool get isNarrowed => filter != HistoryFilter.all || normalizeForSearch(query).isNotEmpty;

  /// Null when the list on screen is the server's, fresh.
  HistoryConnectionNotice? get connectionNotice {
    if (isOffline) return HistoryConnectionNotice.offline;
    if (!isFromCache) return null;
    if (isRefreshing || _reconnectTimer != null) return HistoryConnectionNotice.syncing;
    return HistoryConnectionNotice.serverUnreachable;
  }

  /// On a refresh the current list stays on screen until the new one is in,
  /// like StatsViewModel. Calls made while one is out share it: pull to
  /// refresh and the refresh after reconnecting never run twice.
  Future<void> load() => _loadInFlight ??= _load().whenComplete(() => _loadInFlight = null);

  Future<void> _load() async {
    isRefreshing = status == HistoryStatus.data;
    if (!isRefreshing) status = HistoryStatus.loading;
    errorMessage = null;
    notifyListeners();
    try {
      final catalogFuture = _questRepository.getCatalog();
      // Sends what was queued offline before reading, and falls back to the
      // device's copy without a connection (fast) or past its timeout.
      final (:userQuests, :fromCache) = await _questRepository.getUserQuestsWithSource(_userId);
      _catalog = await catalogFuture;
      _userQuests = userQuests;
      // After the read, which synced: whatever is left is still waiting.
      _pendingSyncIds = _questRepository.pendingSyncAttemptIds();
      _stepTotals = _questRepository.getStepTotals();
      // Also after the read: a fresh one has just saved "now".
      lastSyncedAt = _questRepository.userQuestsSyncedAt();
      isFromCache = fromCache;
      // New data: nothing computed from the previous one is valid anymore.
      _historyCache.clear();
      _searchTimer?.cancel();
      await _rebuild();
    } on AppException catch (e) {
      errorMessage = e.message;
      status = HistoryStatus.error;
    } finally {
      isRefreshing = false;
      notifyListeners();
    }
  }

  void setFilter(HistoryFilter value) {
    if (value == filter) return;
    filter = value;
    // A tap is a decision, not typing in progress: runs now, along with any
    // search still waiting for its pause.
    _searchTimer?.cancel();
    unawaited(_rebuild());
  }

  void setQuery(String value) {
    if (value == query) return;
    query = value;
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDebounce, () => unawaited(_rebuild()));
  }

  /// Runs [buildMissionHistory] off the UI thread with what was loaded and
  /// the current filter/search; only the latest run's answer is applied.
  /// A filter/search already computed over this data comes from the cache.
  Future<void> _rebuild() async {
    // Bumped on a cache hit too: a run still out for an older filter/search
    // must not replace what the cache just showed.
    final generation = ++_generation;
    final cacheKey = (filter, normalizeForSearch(query));
    final cached = _historyCache.get(cacheKey);
    if (cached != null) {
      _show(cached);
      return;
    }

    isUpdating = true;
    notifyListeners();

    final result = await _runner(
      MissionHistoryInput(
        catalog: _catalog,
        userQuests: _userQuests,
        stepTotals: _stepTotals,
        pendingSyncIds: _pendingSyncIds,
        filter: filter,
        query: query,
      ),
    );
    // A stale answer isn't cached either: a load() may have replaced the
    // data it was computed from.
    if (_isDisposed || generation != _generation) return;

    _historyCache.put(cacheKey, result);
    _show(result);
  }

  void _show(MissionHistory result) {
    history = result;
    isUpdating = false;
    if (result.totalAttempts > 0) {
      status = HistoryStatus.data;
    } else if (isFromCache) {
      // Offline and nothing was ever cached: not "you have no missions".
      status = HistoryStatus.error;
      errorMessage = 'Offline and no saved data. Your quest log will load automatically when you are back online.';
    } else {
      status = HistoryStatus.empty;
    }
    notifyListeners();
  }

  /// The first reading, then every change. A change heard while the first
  /// reading is on its way is newer than it (as in ConnectivityViewModel).
  /// No connectivity API (tests, some platforms): stays "online".
  void _watchConnectivity() {
    var heardChange = false;
    try {
      _connectivitySubscription = _offlineChanges().listen((offline) {
        heardChange = true;
        _setOffline(offline);
      }, onError: (Object _) {});
    } catch (_) {}
    Future.sync(_isOffline).then((offline) {
      if (!heardChange) _setOffline(offline);
    }, onError: (Object _) {});
  }

  void _setOffline(bool offline) {
    if (_isDisposed || offline == isOffline) return;
    isOffline = offline;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (!offline) {
      // Only if the connection holds: one that drops again cancels this.
      _reconnectTimer = Timer(_reconnectDelay, () {
        _reconnectTimer = null;
        unawaited(_refreshAfterReconnect());
      });
    }
    notifyListeners();
  }

  /// A load that started offline is coming back from the device: waits for
  /// it, then loads again with the connection.
  Future<void> _refreshAfterReconnect() async {
    await _loadInFlight;
    if (_isDisposed || isOffline) return;
    await load();
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _searchTimer?.cancel();
    _reconnectTimer?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }
}
