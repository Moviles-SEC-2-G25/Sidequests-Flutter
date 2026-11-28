/// Multithreading strategy (Alejandro, Sprint 4): "Evidencias de un intento"
/// does two kinds of background work, and each one gets the tool that fits it.
///
/// 1. Downloads (I/O-bound) -> a pool of Futures with at most
///    [kEvidenceMaxConcurrentDownloads] (3) running at once ([DownloadPool], a
///    counting semaphore). Waiting on the network costs no CPU: Dart's event
///    loop already overlaps several requests on the UI isolate, so a new
///    thread would add nothing. What needs controlling is how many go out at
///    once: an attempt can have many photos, and starting all of them together
///    would split a slow mobile link N ways (every photo late instead of the
///    first ones early), keep N photos' buffers in memory and hit
///    NetworkGuard's 5 s timeout on all of them. The grid and "Guardar todas"
///    share one pool per screen, so together they never pass 3; the rest wait
///    their turn in order, and leaving the screen cancels whatever is still
///    waiting ([DownloadPool.close]).
///
/// 2. Thumbnails (CPU-bound) -> [Isolate.run]. Decoding a JPEG, shrinking it
///    to [kEvidenceThumbnailMaxSide] (320 px) and encoding it again is pure
///    Dart (package `image`) and takes hundreds of milliseconds per photo on a
///    phone: on the UI isolate the grid would freeze while it fills. It runs
///    on a new isolate per photo, with [makeEvidenceThumbnail]: top-level,
///    bytes in and bytes out, so nothing but a Uint8List crosses (the result
///    comes back through Isolate.exit, without a copy). A thumbnail is made
///    inside its download's turn in the pool, so at most 3 of these isolates
///    (and 3 decoded photos) exist at a time.
///
/// How it differs from what the team already uses:
/// - compute() (Lucas: MissionHistoryViewModel and the abandonment
///   alternatives; Julián: StatsViewModel) is Flutter's wrapper over this same
///   primitive, used there for one job at a time over an object graph that is
///   copied to the isolate (the history, the stats) and replaced by the next
///   job when a filter changes. Here the jobs are many and independent, they
///   run in parallel (up to 3), the input is a flat byte buffer (no object
///   graph to copy) and it's plain Dart with no Flutter dependency, so the
///   Dart primitive is used directly.
/// - SimilarQuestWorker (mine, Sprint 4) is ONE long-lived isolate fed by
///   message passing, because "Te podría gustar" is a tiny job repeated on
///   every star tap over the same catalog. Here every photo is a different,
///   heavy and independent input that is processed once: a short-lived
///   isolate per photo (in parallel, bounded by the pool) fits better than a
///   queue behind a single worker, and there is nothing to keep alive.
/// - None of them limit I/O concurrency: that's the pool.
///
/// Measurement (debugPrint, debug builds): every thumbnail logs its time on
/// the isolate and the size before/after; every busy period of a pool logs how
/// many tasks it ran, the total time and the peak concurrency; "Guardar todas"
/// logs its own total. `--dart-define=EVIDENCE_DOWNLOAD_CONCURRENCY=1` builds
/// with a pool of 1 to compare against 3 on the same attempt.
/// Kotlin: Semaphore(3) + withPermit {} around the downloads, and
/// withContext(Dispatchers.Default) for the thumbnail.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// The longest side of a thumbnail: a grid cell is at most ~140 dp, about
/// 320 px on a 2.6x screen.
const kEvidenceThumbnailMaxSide = 320;

/// Enough for a 320 px thumbnail; a fraction of the photo's bytes.
const kEvidenceThumbnailQuality = 75;

/// Downloads at once per screen. `--dart-define=EVIDENCE_DOWNLOAD_CONCURRENCY=1`
/// changes it for the 3-vs-1 measurement.
const kEvidenceMaxConcurrentDownloads = int.fromEnvironment(
  'EVIDENCE_DOWNLOAD_CONCURRENCY',
  defaultValue: 3,
);

/// What makes a thumbnail. Injectable: a real isolate never finishes inside
/// testWidgets' fake async zone, and tests swap in a trivial one.
typedef ThumbnailMaker = Future<Uint8List> Function(Uint8List jpeg);

/// Decodes [jpeg], turns it upright (EXIF orientation), shrinks it so its
/// longest side is [maxSide] (never enlarges it) and encodes it as JPEG.
/// Top-level and pure, bytes in and bytes out, so it can run on another
/// isolate and be tested directly. Throws FormatException for bytes that
/// aren't a JPEG it can decode.
Uint8List makeEvidenceThumbnail(Uint8List jpeg, {int maxSide = kEvidenceThumbnailMaxSide}) {
  final img.Image? decoded;
  try {
    decoded = img.decodeJpg(jpeg);
  } catch (error) {
    // package:image throws its own ImageException for corrupt data.
    throw FormatException('Not a decodable JPEG ($error)');
  }
  if (decoded == null) throw const FormatException('Not a decodable JPEG');
  final upright = img.bakeOrientation(decoded);
  final longest = math.max(upright.width, upright.height);
  final resized = longest <= maxSide
      ? upright
      : img.copyResize(
          upright,
          width: upright.width >= upright.height ? maxSide : null,
          height: upright.height > upright.width ? maxSide : null,
          // Averages every source pixel under each target one: a large
          // reduction without the aliasing of nearest/linear.
          interpolation: img.Interpolation.average,
        );
  return img.encodeJpg(resized, quality: kEvidenceThumbnailQuality);
}

/// [makeEvidenceThumbnail] on a short-lived isolate (inline on the web, which
/// has no isolates), timed with a Stopwatch.
Future<Uint8List> makeEvidenceThumbnailInBackground(Uint8List jpeg) async {
  final stopwatch = Stopwatch()..start();
  final thumbnail = kIsWeb ? makeEvidenceThumbnail(jpeg) : await _onNewIsolate(jpeg);
  debugPrint(
    '[Evidencias] miniatura en Isolate.run: ${stopwatch.elapsedMilliseconds} ms '
    '(${_kb(jpeg.length)} -> ${_kb(thumbnail.length)})',
  );
  return thumbnail;
}

/// A synchronous function of its own, so the closure handed to Isolate.run
/// captures nothing but [jpeg] (a closure inside an async function could
/// capture its whole context, Stopwatch included).
Future<Uint8List> _onNewIsolate(Uint8List jpeg) =>
    Isolate.run(() => makeEvidenceThumbnail(jpeg), debugName: 'evidence-thumbnail');

String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(0)} KB';

/// Thrown to a task that was still waiting for its turn when its pool was
/// closed (the user left the screen).
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  @override
  String toString() => 'DownloadCancelledException';
}

/// A counting semaphore over Futures: [run] starts the task right away while
/// fewer than [maxConcurrent] are running, otherwise it waits in a FIFO queue
/// until one finishes (its slot passes straight to the next in line).
class DownloadPool {
  final int maxConcurrent;
  final String _name;
  final void Function(String message) _log;

  int _active = 0;
  int _peak = 0;
  final _waiting = ListQueue<Completer<void>>();
  bool _closed = false;

  // The current busy period (first task in -> pool idle again), measured.
  final _busy = Stopwatch();
  int _tasksInPeriod = 0;
  int _peakInPeriod = 0;

  DownloadPool({
    this.maxConcurrent = kEvidenceMaxConcurrentDownloads,
    String? name,
    void Function(String message)? log,
  }) : assert(maxConcurrent > 0),
       _name = name ?? 'descargas',
       _log = log ?? debugPrint;

  /// Tasks running right now.
  int get active => _active;

  /// Tasks waiting for a turn.
  int get waiting => _waiting.length;

  /// The most tasks that ever ran at the same time in this pool.
  int get peakActive => _peak;

  bool get isClosed => _closed;

  /// Runs [task] when there's a free slot. Throws [DownloadCancelledException]
  /// if the pool is closed before its turn comes (or already was).
  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  /// Cancels every task still waiting; the ones running finish (an HTTP
  /// download can't be stopped halfway here) and their slots are not passed
  /// on. No new task is accepted.
  void close() {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().completeError(const DownloadCancelledException());
    }
  }

  Future<void> _acquire() {
    if (_closed) return Future.error(const DownloadCancelledException());
    if (_active == 0 && _waiting.isEmpty) _startPeriod();
    _tasksInPeriod++;
    if (_active < maxConcurrent) {
      _setActive(_active + 1);
      return Future.value();
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      // The slot goes straight to the next task: _active doesn't change.
      _waiting.removeFirst().complete();
      return;
    }
    _setActive(_active - 1);
    if (_active == 0) _endPeriod();
  }

  void _setActive(int value) {
    _active = value;
    _peak = math.max(_peak, value);
    _peakInPeriod = math.max(_peakInPeriod, value);
  }

  void _startPeriod() {
    _tasksInPeriod = 0;
    _peakInPeriod = 0;
    _busy
      ..reset()
      ..start();
  }

  void _endPeriod() {
    _busy.stop();
    _log(
      '[Evidencias] pool de $_name: $_tasksInPeriod tareas en ${_busy.elapsedMilliseconds} ms '
      '(máximo $maxConcurrent a la vez, pico $_peakInPeriod)',
    );
  }
}
