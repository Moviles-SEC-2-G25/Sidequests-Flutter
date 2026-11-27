/// Multithreading strategy (Alejandro, Sprint 4): "Te podría gustar" on
/// QuestCompletedView is ranked by a long-lived worker isolate, reached by
/// message passing (SendPort/ReceivePort), instead of on the UI thread.
///
/// The ranking (SimilarQuestRecommender) runs again on every star the user
/// taps, right while the stars and the list repaint. Each run is small, but it
/// walks the whole catalog. compute() — what StatsViewModel,
/// MissionHistoryViewModel and the abandonment alternatives use — spawns a new
/// isolate and copies its whole input on every call: for a small job repeated
/// on every tap, the spawn and the copy of the catalog would cost more than the
/// ranking itself. So this worker is spawned once, the first time the screen
/// needs it, and kept while the app lives; the catalog is copied to it only
/// when it changes, and each tap sends just a few small values (the completed
/// quest's id, the rating, the minutes, the unavailable ids) with a requestId.
/// QuestViewModel applies only the answer to its latest requestId, so quick
/// taps never leave an older ranking on screen. Every message is plain data
/// (Maps, Lists, primitives).
///
/// It never leaves the screen without suggestions: if the worker crashes,
/// exits or takes more than [kSimilarQuestWorkerTimeout], that request is
/// ranked on the UI thread with the same pure function ([rankSimilarQuests]),
/// and a new worker is spawned on the next request. On the web (no isolates)
/// it ranks directly. Disposing QuestViewModel and signing out kill the isolate
/// and close its ports. Kotlin: one long-lived single-thread dispatcher fed by
/// a Channel (an actor), not a new coroutine per tap.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../models/quest.dart';
import '../memo.dart';
import '../similar_quest_recommender.dart';

/// After this long without an answer the worker counts as hung: the request is
/// ranked on the UI thread and the worker is replaced on the next one.
const kSimilarQuestWorkerTimeout = Duration(seconds: 2);

/// `--dart-define=SIMILAR_QUESTS_ON_UI_THREAD=true` ranks on the UI thread, as
/// before the worker, to measure the "before" on a phone with the same logs.
const _rankOnUiThreadByDefine = bool.fromEnvironment('SIMILAR_QUESTS_ON_UI_THREAD');

// Message types. Requests: catalog, recommend. Replies: result, error.
const _catalogMessage = 'catalog';
const _recommendMessage = 'recommend';
const _resultMessage = 'result';
const _errorMessage = 'error';

/// What one ranking needs besides the catalog. All small: this, not the
/// catalog, is what crosses to the worker on every star tap.
class SimilarQuestQuery {
  final Quest completed;

  /// The pending (not yet saved) rating; 0 = no stars yet.
  final int rating;
  final int maxMinutes;

  /// From SimilarQuestRecommender.unavailableQuestIds.
  final Set<String> unavailableQuestIds;

  const SimilarQuestQuery({
    required this.completed,
    required this.rating,
    required this.maxMinutes,
    required this.unavailableQuestIds,
  });
}

/// The ranking every path runs — the worker, its UI-thread fallback, the web
/// and the tests: SimilarQuestRecommender as is, so the answer is the same
/// wherever it ran.
List<Quest> rankSimilarQuests(List<Quest> catalog, SimilarQuestQuery query) =>
    const SimilarQuestRecommender().recommendExcluding(
      query.completed,
      catalog,
      query.unavailableQuestIds,
      query.rating,
      query.maxMinutes,
    );

enum SimilarQuestThread { worker, uiThread }

class SimilarQuestAnswer {
  /// The request this answers, as it was sent.
  final int requestId;

  /// The objects of the catalog the request was made with, best first.
  final List<Quest> quests;
  final SimilarQuestThread rankedOn;

  /// Why it was ranked on the UI thread when a worker should have done it.
  final String? fallbackReason;

  /// What this request cost the UI thread: sending it and reading the answer,
  /// or the whole ranking when it ran there.
  final Duration uiThreadTime;

  /// How long the ranking took inside the worker — what the UI thread would
  /// have spent on it. null when it didn't run there.
  final Duration? workerTime;

  const SimilarQuestAnswer({
    required this.requestId,
    required this.quests,
    required this.rankedOn,
    this.fallbackReason,
    required this.uiThreadTime,
    this.workerTime,
  });
}

/// How QuestViewModel gets "Te podría gustar" ranked. Injectable because a
/// real isolate never answers inside testWidgets' fake async zone: widget
/// tests use [SynchronousSimilarQuestRunner].
abstract interface class SimilarQuestRunner {
  /// Ranks [catalog] for [query]; the answer carries [requestId] back. Never
  /// fails: a worker problem is answered from the UI thread.
  Future<SimilarQuestAnswer> recommend({
    required int requestId,
    required List<Quest> catalog,
    required SimilarQuestQuery query,
  });

  /// Releases what it holds (the worker isolate and its ports). Requests
  /// still out are answered from the UI thread; a later request starts over.
  void close();
}

/// Ranks on the calling (UI) thread, as before the worker: the web build,
/// widget tests, and the "before" of the measurements.
class SynchronousSimilarQuestRunner implements SimilarQuestRunner {
  const SynchronousSimilarQuestRunner();

  @override
  Future<SimilarQuestAnswer> recommend({
    required int requestId,
    required List<Quest> catalog,
    required SimilarQuestQuery query,
  }) {
    final stopwatch = Stopwatch()..start();
    final quests = rankSimilarQuests(catalog, query);
    // Future.value, not SynchronousFuture: the caller applies the answer in a
    // microtask, never in the middle of the build that asked for it.
    return Future.value(
      SimilarQuestAnswer(
        requestId: requestId,
        quests: quests,
        rankedOn: SimilarQuestThread.uiThread,
        uiThreadTime: stopwatch.elapsed,
      ),
    );
  }

  @override
  void close() {}
}

/// The worker isolate's client: spawns it lazily, keeps it, keeps its copy of
/// the catalog up to date, and falls back to the UI thread when it fails.
/// Session-owned (app.dart): signing out ([clear]) kills it like dispose.
class SimilarQuestWorker implements SimilarQuestRunner, SessionCache {
  SimilarQuestWorker({
    bool? useIsolate,
    this._timeout = kSimilarQuestWorkerTimeout,
    void Function(String message)? log,
    @visibleForTesting this._entryPoint = similarQuestWorkerMain,
  }) : _useIsolate = useIsolate ?? (!kIsWeb && !_rankOnUiThreadByDefine),
       _log = log ?? _debugLog;

  final bool _useIsolate;
  final Duration _timeout;
  final void Function(String message) _log;
  final void Function(SendPort replies) _entryPoint;

  /// The worker in use; null until the first request and after it was lost.
  _WorkerSession? _session;

  /// Requests sent (or waiting for the worker to start) and not answered yet.
  final Map<int, _PendingRequest> _pending = {};

  /// Bumped on every catalog sent, across workers, so a version never repeats.
  int _catalogVersion = 0;

  /// Catalog object by id, to turn the worker's ids back into the very
  /// objects the UI thread has. Rebuilt only when the catalog list changes.
  List<Quest>? _indexedCatalog;
  Map<String, Quest> _questsById = const {};

  int _spawnCount = 0;
  int _catalogMessagesSent = 0;
  int _fallbackCount = 0;
  Duration? _lastSpawnTime;
  Duration? _lastCatalogSyncTime;

  /// Workers started so far: 1 while the first one lives.
  int get spawnCount => _spawnCount;

  /// "catalog" messages sent: one per worker and catalog content.
  int get catalogMessagesSent => _catalogMessagesSent;

  /// Requests ranked on the UI thread because the worker failed.
  int get fallbackCount => _fallbackCount;

  /// From spawning the last worker to its first message (ready to work).
  Duration? get lastSpawnTime => _lastSpawnTime;

  /// UI-thread time of the last catalog change: indexing it and copying it
  /// to the worker.
  Duration? get lastCatalogSyncTime => _lastCatalogSyncTime;

  /// A worker is up and answering.
  bool get isRunning => _session?.requests != null;

  @visibleForTesting
  Isolate? get debugIsolate => _session?.isolate;

  @override
  Future<SimilarQuestAnswer> recommend({
    required int requestId,
    required List<Quest> catalog,
    required SimilarQuestQuery query,
  }) {
    if (!_useIsolate) return _rankDirectly(requestId, catalog, query);
    assert(!_pending.containsKey(requestId), 'requestId $requestId is already out');

    final request = _PendingRequest(requestId, catalog, query);
    _pending[requestId] = request;
    request.timer = Timer(_timeout, () {
      if (identical(_pending[requestId], request)) {
        _fail(_session, 'no answer within ${_timeout.inMilliseconds} ms');
      }
    });

    final session = _session ??= _startSession();
    if (session.requests == null) {
      session.waiting.add(request);
    } else {
      _send(session, request);
    }
    return request.completer.future;
  }

  /// Kills the worker and closes its ports; whatever was still out is
  /// answered from the UI thread. The next request spawns a new worker.
  @override
  void close() {
    final session = _session;
    if (session == null && _pending.isEmpty) return;
    _endSession();
    if (session != null) _log('worker closed');
    _fallBackAll('worker closed');
  }

  /// Signing out (AuthRepository): the worker and its copy of the catalog
  /// belong to the session.
  @override
  void clear() => close();

  _WorkerSession _startSession() {
    final session = _WorkerSession();
    _spawnCount++;
    final spawnStopwatch = Stopwatch()..start();

    session.replies.listen((message) {
      // The handshake: the first message is where to send requests.
      if (message is SendPort) {
        _onReady(session, message, spawnStopwatch.elapsed);
      } else {
        _onReply(session, message);
      }
    });
    // onError sends [error, stack trace] as strings; onExit sends null.
    session.lifecycle.listen((message) {
      _fail(session, message is List ? 'crashed: ${message.first}' : 'exited');
    });

    // Future.sync: even a synchronous failure arrives after _session is set.
    Future.sync(
      () => Isolate.spawn(
        _entryPoint,
        session.replies.sendPort,
        onError: session.lifecycle.sendPort,
        onExit: session.lifecycle.sendPort,
        debugName: 'SimilarQuestWorker',
      ),
    ).then((isolate) {
      // Closed (timeout, sign-out) while it was starting.
      if (session.isClosed) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        session.isolate = isolate;
      }
    }, onError: (Object error) => _fail(session, 'could not start: $error'));
    return session;
  }

  void _onReady(_WorkerSession session, SendPort requests, Duration spawnTime) {
    if (session.isClosed) return;
    session.requests = requests;
    _lastSpawnTime = spawnTime;
    _log('isolate ready in ${_ms(spawnTime)} (paid once per worker)');
    final waiting = [...session.waiting];
    session.waiting.clear();
    for (final request in waiting) {
      if (identical(_pending[request.requestId], request)) _send(session, request);
    }
  }

  void _send(_WorkerSession session, _PendingRequest request) {
    try {
      _syncCatalog(session, request.catalog);
      request.questsById = _questsById;
      final stopwatch = Stopwatch()..start();
      final completed = request.query.completed;
      session.requests!.send({
        'type': _recommendMessage,
        'requestId': request.requestId,
        'catalogVersion': session.catalogVersion,
        'completedId': completed.id,
        // Usually the catalog's own object, which the worker already has; if
        // not, the quest itself goes along (still one quest, not the catalog).
        if (!identical(request.questsById[completed.id], completed))
          'completed': questToWorkerMessage(completed),
        'rating': request.query.rating,
        'maxMinutes': request.query.maxMinutes,
        'unavailableIds': request.query.unavailableQuestIds.toList(),
      });
      request.uiThreadTime += stopwatch.elapsed;
    } catch (error) {
      _fail(session, 'could not send: $error');
    }
  }

  /// Sends the catalog only when the worker doesn't have this content yet.
  /// QuestViewModel replaces its catalog list, never edits it in place, so the
  /// same list means the same content (O(1) on every tap); a new list is
  /// compared field by field, so a reload that brings the same catalog isn't
  /// copied again.
  void _syncCatalog(_WorkerSession session, List<Quest> catalog) {
    if (identical(session.catalog, catalog) && identical(_indexedCatalog, catalog)) return;
    final stopwatch = Stopwatch()..start();

    if (!identical(_indexedCatalog, catalog)) {
      _indexedCatalog = catalog;
      _questsById = {for (final quest in catalog) quest.id: quest};
    }
    if (identical(session.catalog, catalog)) return;

    final encoded = [for (final quest in catalog) questToWorkerMessage(quest)];
    final sent = session.catalogMessage;
    if (sent == null || !_sameCatalogMessage(sent, encoded)) {
      session.catalogVersion = ++_catalogVersion;
      session.requests!.send({
        'type': _catalogMessage,
        'version': session.catalogVersion,
        'quests': encoded,
      });
      _catalogMessagesSent++;
      _lastCatalogSyncTime = stopwatch.elapsed;
      _log(
        'catalog v${session.catalogVersion} copied to the worker '
        '(${catalog.length} quests) · UI thread ${_ms(stopwatch.elapsed)}, once per change',
      );
    } else {
      _log(
        'catalog reloaded with the same content: not copied again (${_ms(stopwatch.elapsed)} to check)',
      );
    }
    session.catalog = catalog;
    session.catalogMessage = encoded;
  }

  void _onReply(_WorkerSession session, Object? message) {
    if (session.isClosed) return;
    final stopwatch = Stopwatch()..start();
    final fields = (message as Map).cast<String, Object?>();
    final request = _pending[fields['requestId']];
    // Already answered from the UI thread.
    if (request == null) return;
    if (fields['type'] == _errorMessage) {
      _fail(session, 'error: ${fields['error']}');
      return;
    }

    final quests = <Quest>[];
    for (final id in (fields['questIds'] as List).cast<String>()) {
      final quest = request.questsById[id];
      if (quest == null) {
        _fail(session, 'answered with $id, which is not in the catalog');
        return;
      }
      quests.add(quest);
    }
    _pending.remove(request.requestId);
    request.timer?.cancel();

    final uiThreadTime = request.uiThreadTime + stopwatch.elapsed;
    final workerTime = Duration(microseconds: fields['workerMicros'] as int);
    _log(
      '#${request.requestId} (${request.query.rating}★) ranked in the worker: '
      'UI thread ${_ms(uiThreadTime)} · ranking ${_ms(workerTime)} (the UI thread is spared that) '
      '· round trip ${_ms(request.roundTrip.elapsed)}',
    );
    request.completer.complete(
      SimilarQuestAnswer(
        requestId: request.requestId,
        quests: quests,
        rankedOn: SimilarQuestThread.worker,
        uiThreadTime: uiThreadTime,
        workerTime: workerTime,
      ),
    );
  }

  /// The worker [session] is lost: it's killed, whatever it had is answered
  /// from the UI thread, and the next request starts a new one.
  void _fail(_WorkerSession? session, String reason) {
    if (session == null || !identical(session, _session)) return;
    _log(
      'worker lost ($reason): answering from the UI thread; a new one starts on the next request',
    );
    _endSession();
    _fallBackAll(reason);
  }

  void _endSession() {
    final session = _session;
    _session = null;
    session?.close();
  }

  void _fallBackAll(String reason) {
    final requests = [..._pending.values];
    _pending.clear();
    for (final request in requests) {
      request.timer?.cancel();
      request.completer.complete(_rankOnUiThread(request, reason));
    }
  }

  SimilarQuestAnswer _rankOnUiThread(_PendingRequest request, String reason) {
    _fallbackCount++;
    final stopwatch = Stopwatch()..start();
    final quests = rankSimilarQuests(request.catalog, request.query);
    final time = stopwatch.elapsed;
    _log(
      '#${request.requestId} (${request.query.rating}★) ranked on the UI thread ($reason): ${_ms(time)}',
    );
    return SimilarQuestAnswer(
      requestId: request.requestId,
      quests: quests,
      rankedOn: SimilarQuestThread.uiThread,
      fallbackReason: reason,
      uiThreadTime: request.uiThreadTime + time,
    );
  }

  Future<SimilarQuestAnswer> _rankDirectly(
    int requestId,
    List<Quest> catalog,
    SimilarQuestQuery query,
  ) async {
    final answer = await const SynchronousSimilarQuestRunner().recommend(
      requestId: requestId,
      catalog: catalog,
      query: query,
    );
    _log(
      '#$requestId (${query.rating}★) ranked on the UI thread (no worker): ${_ms(answer.uiThreadTime)}',
    );
    return answer;
  }
}

/// One worker isolate and its two ports: [replies] (handshake, then answers)
/// and [lifecycle] (onError/onExit).
class _WorkerSession {
  final replies = ReceivePort('SimilarQuestWorker replies');
  final lifecycle = ReceivePort('SimilarQuestWorker lifecycle');
  Isolate? isolate;

  /// Where to send requests; null until the worker's first message.
  SendPort? requests;
  bool isClosed = false;

  /// Requests made before [requests] arrived, in order.
  final List<_PendingRequest> waiting = [];

  /// The catalog this worker has: the list, its encoded content and version.
  List<Quest>? catalog;
  List<Map<String, Object?>>? catalogMessage;
  int? catalogVersion;

  void close() {
    isClosed = true;
    isolate?.kill(priority: Isolate.immediate);
    replies.close();
    lifecycle.close();
  }
}

class _PendingRequest {
  final int requestId;
  final List<Quest> catalog;
  final SimilarQuestQuery query;
  final completer = Completer<SimilarQuestAnswer>();
  final roundTrip = Stopwatch()..start();
  Timer? timer;
  Map<String, Quest> questsById = const {};
  Duration uiThreadTime = Duration.zero;

  _PendingRequest(this.requestId, this.catalog, this.query);
}

/// A [Quest] as plain data for the worker, with Quest.fromJson's keys so the
/// isolate rebuilds it with that same parser. Every field goes, not only the
/// ones the ranking reads today, so a new rule can't see a different quest
/// there: a field added to Quest must be added here too.
Map<String, Object?> questToWorkerMessage(Quest quest) => {
  'id': quest.id,
  'title': quest.title,
  'description': quest.description,
  'category': quest.category,
  'emoji': quest.emoji,
  'duration_minutes': quest.durationMinutes,
  'estimated_cost': quest.estimatedCost,
  'difficulty': quest.difficulty,
  'location_mode': quest.locationMode,
  'social_level': quest.socialLevel,
  'location_name': quest.locationName,
  'latitude': quest.latitude,
  'longitude': quest.longitude,
  'tags': quest.tags,
  'is_new': quest.isNew,
  'is_sponsored': quest.isSponsored,
  'sponsor_name': quest.sponsorName,
  'sponsor_business_category': quest.sponsorBusinessCategory,
  'is_group': quest.isGroup,
};

bool _sameCatalogMessage(List<Map<String, Object?>> a, List<Map<String, Object?>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final left = a[i];
    final right = b[i];
    if (left.length != right.length) return false;
    for (final MapEntry(:key, :value) in left.entries) {
      final other = right[key];
      final same = value is List && other is List ? listEquals(value, other) : value == other;
      if (!same) return false;
    }
  }
  return true;
}

/// The worker isolate: keeps its copy of the catalog and answers each
/// "recommend" with the ids [rankSimilarQuests] picks. Top level so
/// Isolate.spawn can start it.
@pragma('vm:entry-point')
void similarQuestWorkerMain(SendPort replies) {
  final requests = ReceivePort();
  replies.send(requests.sendPort);

  var catalog = const <Quest>[];
  var questsById = const <String, Quest>{};
  int? catalogVersion;

  requests.listen((message) {
    final fields = (message as Map).cast<String, Object?>();
    switch (fields['type']) {
      case _catalogMessage:
        catalog = [
          for (final quest in fields['quests'] as List)
            Quest.fromJson((quest as Map).cast<String, dynamic>()),
        ];
        questsById = {for (final quest in catalog) quest.id: quest};
        catalogVersion = fields['version'] as int;
      case _recommendMessage:
        replies.send(_answerInWorker(fields, catalog, questsById, catalogVersion));
    }
  });
}

Map<String, Object?> _answerInWorker(
  Map<String, Object?> fields,
  List<Quest> catalog,
  Map<String, Quest> questsById,
  int? catalogVersion,
) {
  final requestId = fields['requestId'] as int;
  try {
    if (fields['catalogVersion'] != catalogVersion) {
      throw StateError('has catalog v$catalogVersion, asked for v${fields['catalogVersion']}');
    }
    final completedFields = fields['completed'];
    final completed = completedFields == null
        ? questsById[fields['completedId']] ??
              (throw StateError('completed quest not in the catalog'))
        : Quest.fromJson((completedFields as Map).cast<String, dynamic>());
    final stopwatch = Stopwatch()..start();
    final quests = rankSimilarQuests(
      catalog,
      SimilarQuestQuery(
        completed: completed,
        rating: fields['rating'] as int,
        maxMinutes: fields['maxMinutes'] as int,
        unavailableQuestIds: (fields['unavailableIds'] as List).cast<String>().toSet(),
      ),
    );
    return {
      'type': _resultMessage,
      'requestId': requestId,
      'questIds': [for (final quest in quests) quest.id],
      'workerMicros': stopwatch.elapsedMicroseconds,
    };
  } catch (error) {
    return {'type': _errorMessage, 'requestId': requestId, 'error': '$error'};
  }
}

/// Debug and profile builds only (`flutter run --profile` shows it), for the
/// wiki's before/after; a release build logs nothing.
void _debugLog(String message) {
  if (!kReleaseMode) debugPrint('SimilarQuestWorker: $message');
}

String _ms(Duration duration) => '${(duration.inMicroseconds / 1000).toStringAsFixed(2)} ms';
