import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/bq11/block_dwell_meter.dart';
import 'package:sidequests/core/bq11/commercial_blocks.dart';

const _attempt = 'uq-1';
const _paloquemao = (lat: 4.616, lon: -74.08426);
const _usaquen = (lat: 4.69577, lon: -74.031);

void main() {
  // Kotlin's test start: Saturday 2026-11-28, 20:00 in Bogotá.
  final saturday = DateTime.utc(2026, 11, 29, 1);
  final thursday = DateTime.utc(2026, 11, 26, 18);
  late BlockDwellMeter meter;

  setUp(() => meter = BlockDwellMeter()..select(_attempt));

  /// A fresh, precise reading [seconds] after [start], received right away.
  void readAt(
    int seconds, {
    DateTime? start,
    ({double lat, double lon}) place = _paloquemao,
    double accuracy = 5,
    Duration age = Duration.zero,
    bool isMocked = false,
    String attempt = _attempt,
  }) {
    final fixTime = (start ?? saturday).add(Duration(seconds: seconds));
    meter.recordFix(
      attemptId: attempt,
      latitude: place.lat,
      longitude: place.lon,
      accuracyMeters: accuracy,
      fixTime: fixTime,
      receivedAt: fixTime.add(age),
      elapsed: Duration(seconds: seconds),
      isMocked: isMocked,
    );
  }

  /// One reading every 15 s from [from], [intervals] intervals in all.
  void readEvery15s(
    int intervals, {
    int from = 0,
    DateTime? start,
    ({double lat, double lon}) place = _paloquemao,
  }) {
    for (var i = 0; i <= intervals; i++) {
      readAt(from + i * 15, start: start, place: place);
    }
  }

  List<BlockDwell> finish({DateTime? at}) =>
      meter.finish(attemptId: _attempt, completedAt: at ?? saturday.add(const Duration(hours: 1)));

  group('the 20-minute threshold is strict', () {
    test('80 intervals of 15 s = 1,200,000 ms: not enough', () {
      readEvery15s(80);

      expect(finish(), isEmpty);
    });

    test('81 intervals = 1,215,000 ms: counts, as in Kotlin', () {
      readEvery15s(81);

      expect(finish(), [
        BlockDwell(
          blockId: kBq11PaloquemaoBlockId,
          weekendStart: DateTime.utc(2026, 11, 28),
          observedMs: 1215000,
        ),
      ]);
    });
  });

  group('what cuts an interval', () {
    test('a gap over 35 s is not counted; exactly 35 s is', () {
      readAt(0);
      readAt(35); // +35 s: counts
      readAt(71); // +36 s: cut
      readEvery15s(78, from: 71); // the rest: 78 intervals

      // 35 s + 78 × 15 s = 1,205,000: only over the threshold thanks to the 35 s.
      expect(finish().single.observedMs, 1205000);
    });

    test('changing block starts over in the new one, never summing the two', () {
      readEvery15s(40); // 0..600 s in Paloquemao: 600,000 ms
      readEvery15s(40, from: 615, place: _usaquen); // 615..1215 s in Usaquén: 600,000 ms

      // Summed (or counting the jump) it would be 1,215,000 and pass.
      expect(finish(), isEmpty);
    });

    test('hiding the screen (or the app going to the background) cuts it', () {
      readEvery15s(40); // 0..600 s
      meter.setVisible(false);
      readAt(615); // ignored while hidden
      meter.setVisible(true);
      readEvery15s(40, from: 630); // 630..1230 s

      // Without the cut, 600 -> 630 (30 s) would count too: 1,230,000.
      expect(finish(), isEmpty); // 80 intervals: exactly 1,200,000
    });

    test('a pause (no reading available) cuts it too', () {
      readEvery15s(40);
      meter.pause();
      readEvery15s(40, from: 615);

      // Without the pause, 600 -> 615 would count: 81 intervals.
      expect(finish(), isEmpty);
    });

    test('a stale, mocked, imprecise or out-of-area fix cuts it', () {
      for (final invalid in <void Function(int)>[
        (s) => readAt(s, age: const Duration(seconds: 6)),
        (s) => readAt(s, isMocked: true),
        (s) => readAt(s, accuracy: 40),
        (s) => readAt(s, place: (lat: 4.601, lon: -74.065)),
      ]) {
        meter.select(_attempt);
        readEvery15s(40);
        invalid(615);
        readEvery15s(40, from: 630);

        // A valid fix at 615 would add 30 s: 82 intervals.
        expect(finish(), isEmpty);
      }
    });

    test('a fix up to 5 s old still counts', () {
      for (var i = 0; i <= 81; i++) {
        readAt(i * 15, age: const Duration(seconds: 5));
      }

      expect(finish().single.observedMs, 1215000);
    });
  });

  test('control: the same sequences with nothing cutting them do count', () {
    readEvery15s(40);
    readAt(615);
    readEvery15s(40, from: 630);

    expect(finish().single.observedMs, 1230000);
  });

  group('weekends in Bogotá', () {
    test('Saturday 00:00 to Sunday 23:59 local; Friday and Monday are out', () {
      expect(bogotaWeekendStart(DateTime.utc(2026, 11, 28, 4, 59, 59)), isNull); // Fri 23:59:59
      expect(bogotaWeekendStart(DateTime.utc(2026, 11, 28, 5)), DateTime.utc(2026, 11, 28)); // Sat 00:00
      expect(bogotaWeekendStart(DateTime.utc(2026, 11, 30, 4, 59)), DateTime.utc(2026, 11, 28)); // Sun 23:59
      expect(bogotaWeekendStart(DateTime.utc(2026, 11, 30, 5)), isNull); // Mon 00:00
    });

    test('weekend_start is written like Kotlin\'s LocalDate', () {
      expect(formatWeekendStart(DateTime.utc(2026, 11, 28)), '2026-11-28');
      expect(formatWeekendStart(DateTime.utc(2027, 1, 2)), '2027-01-02');
    });

    test('on a weekday nothing counts', () {
      readEvery15s(100, start: thursday);

      expect(finish(at: thursday.add(const Duration(hours: 1))), isEmpty);
    });

    test('time from a weekend that is not the completion\'s is left out', () {
      readEvery15s(90);

      expect(finish(at: saturday.add(const Duration(days: 7))), isEmpty);
    });
  });

  group('attempts', () {
    test('readings of another attempt are ignored', () {
      for (var i = 0; i <= 90; i++) {
        readAt(i * 15, attempt: 'uq-other');
      }

      expect(finish(), isEmpty);
    });

    test('finishing another attempt returns nothing and keeps this one', () {
      readEvery15s(81);

      expect(meter.finish(attemptId: 'uq-other', completedAt: saturday), isEmpty);
      expect(finish(), hasLength(1));
    });

    test('select(null) discards the measurement; finish ends it', () {
      readEvery15s(81);
      meter.select(null);
      expect(meter.attemptId, isNull);
      meter.select(_attempt);
      expect(finish(), isEmpty);

      meter.select(_attempt);
      readEvery15s(81);
      expect(finish(), hasLength(1));
      expect(meter.attemptId, isNull);
    });
  });
}
