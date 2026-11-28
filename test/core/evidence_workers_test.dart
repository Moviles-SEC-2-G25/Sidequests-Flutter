import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sidequests/core/workers/evidence_workers.dart';

import '../helpers/evidence_fakes.dart';

void main() {
  group('DownloadPool', () {
    test('never runs more than 3 at once; the rest wait their turn, in order', () async {
      final logs = <String>[];
      final pool = DownloadPool(maxConcurrent: 3, log: logs.add);
      final gates = [for (var i = 0; i < 8; i++) Completer<void>()];
      final started = <int>[];
      var running = 0;
      var peak = 0;

      final tasks = [
        for (var i = 0; i < 8; i++)
          pool.run(() async {
            started.add(i);
            running++;
            if (running > peak) peak = running;
            await gates[i].future;
            running--;
            return i;
          }),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2]);
      expect(pool.active, 3);
      expect(pool.waiting, 5);

      gates[1].complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, [0, 1, 2, 3]); // the freed slot goes to the next in line

      for (final gate in gates) {
        if (!gate.isCompleted) gate.complete();
      }
      expect(await Future.wait(tasks), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(peak, 3);
      expect(pool.peakActive, 3);
      expect(pool.active, 0);
      expect(logs.single, contains('8 tareas'));
      expect(logs.single, contains('pico 3'));
    });

    test('a failing task frees its slot and doesn\'t affect the others', () async {
      final pool = DownloadPool(maxConcurrent: 1, log: (_) {});
      final failing = pool.run<int>(() async => throw StateError('boom'));
      final next = pool.run(() async => 2);

      await expectLater(failing, throwsStateError);
      expect(await next, 2);
    });

    test('close() cancels what is still waiting; what is running finishes', () async {
      final pool = DownloadPool(maxConcurrent: 3, log: (_) {});
      final gate = Completer<void>();
      var started = 0;
      final tasks = [
        for (var i = 0; i < 6; i++)
          pool.run(() async {
            started++;
            await gate.future;
            return i;
          }),
      ];
      await Future<void>.delayed(Duration.zero);

      pool.close();
      gate.complete();

      final outcomes = await Future.wait(
        tasks.map((task) => task.then<Object>((value) => value, onError: (Object error) => error)),
      );
      expect(outcomes.take(3), [0, 1, 2]);
      expect(outcomes.skip(3), everyElement(isA<DownloadCancelledException>()));
      expect(started, 3);
      await expectLater(pool.run(() async => 1), throwsA(isA<DownloadCancelledException>()));
    });

    test('defaults to 3 (EVIDENCE_DOWNLOAD_CONCURRENCY not defined)', () {
      expect(kEvidenceMaxConcurrentDownloads, 3);
      expect(DownloadPool().maxConcurrent, 3);
    });
  });

  group('makeEvidenceThumbnail (the function the isolate runs)', () {
    test('shrinks a landscape photo to 320 px on its longest side, keeping the aspect ratio', () {
      final photo = testJpeg(1600, 1200);

      final thumbnail = makeEvidenceThumbnail(photo);

      final decoded = img.decodeJpg(thumbnail)!;
      expect(decoded.width, 320);
      expect(decoded.height, 240);
      expect(thumbnail.length, lessThan(photo.length ~/ 4));
    });

    test('portrait photos are limited by their height', () {
      final decoded = img.decodeJpg(makeEvidenceThumbnail(testJpeg(900, 1600)))!;
      expect(decoded.height, 320);
      expect(decoded.width, 180);
    });

    test('a photo already small is not enlarged', () {
      final decoded = img.decodeJpg(makeEvidenceThumbnail(testJpeg(200, 100)))!;
      expect(decoded.width, 200);
      expect(decoded.height, 100);
    });

    test('bytes that are not a JPEG throw FormatException', () {
      expect(() => makeEvidenceThumbnail(fakeJpeg(1)), throwsFormatException);
    });

    test('really runs on another isolate (Isolate.run), bytes in and bytes out', () async {
      final thumbnail = await makeEvidenceThumbnailInBackground(testJpeg(1600, 1200));
      expect(img.decodeJpg(thumbnail)!.width, 320);
    });
  });
}
