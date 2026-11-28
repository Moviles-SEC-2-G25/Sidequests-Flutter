import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequests/data/local/evidence_store.dart';
import 'package:sidequests/data/local/local_data_source.dart';

Uint8List _bytes(int length, [int value = 7]) => Uint8List.fromList(List.filled(length, value));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  late Directory temp;
  late Directory folder;
  late DateTime clock;
  final logs = <String>[];

  /// Every call is a minute later, so lastOpenedAt orders reads and saves.
  DateTime tick() => clock = clock.add(const Duration(minutes: 1));

  EvidenceStore newStore({int budgetBytes = kEvidenceStoreBudgetBytes, EvidenceFileWriter? writeBytes}) =>
      EvidenceStore(
        budgetBytes: budgetBytes,
        folder: () async => folder,
        now: tick,
        writeBytes: writeBytes,
        log: logs.add,
        isSupported: true,
      );

  /// An app restart: the box is closed and opened again from disk.
  Future<EvidenceStore> restart({int budgetBytes = kEvidenceStoreBudgetBytes}) async {
    await Hive.close();
    Hive.init(temp.path);
    return newStore(budgetBytes: budgetBytes);
  }

  Future<void> save(EvidenceStore store, String attemptId, String proofId, {int photo = 100, int thumb = 10}) async {
    final saved = await store.save(
      attemptId: attemptId,
      proofId: proofId,
      photo: _bytes(photo),
      thumbnail: _bytes(thumb, 1),
    );
    expect(saved, isTrue, reason: 'save of $proofId');
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('evidence_store_test');
    folder = Directory('${temp.path}/evidence');
    clock = DateTime.utc(2026, 11, 1);
    logs.clear();
    Hive.init(temp.path);
  });

  tearDown(() async {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    await temp.delete(recursive: true);
  });

  group('save / read and the index', () {
    test('a saved photo and its thumbnail are JPEG files under evidence/<attempt>/, read back as saved', () async {
      final store = newStore();
      final photo = _bytes(500, 3);
      final thumbnail = _bytes(40, 4);

      expect(
        await store.save(attemptId: 'attempt-1', proofId: 'proof-1', photo: photo, thumbnail: thumbnail),
        isTrue,
      );

      expect(File('${folder.path}/attempt-1/proof-1.jpg').readAsBytesSync(), photo);
      expect(File('${folder.path}/attempt-1/proof-1_thumb.jpg').readAsBytesSync(), thumbnail);
      expect(await store.readPhoto('proof-1'), photo);
      expect(await store.readThumbnail('proof-1'), thumbnail);
      expect(await store.savedProofIds(['proof-1', 'proof-2']), {'proof-1'});
      expect(await store.readPhoto('proof-2'), isNull);
    });

    test('the index keeps relative paths, bytes, savedAt and lastOpenedAt, and survives a restart', () async {
      var store = newStore();
      await save(store, 'attempt-1', 'proof-1', photo: 500, thumb: 40);
      final saved = (await store.entryFor('proof-1'))!;
      expect(saved.attemptId, 'attempt-1');
      expect(saved.photoPath, 'attempt-1/proof-1.jpg');
      expect(saved.thumbnailPath, 'attempt-1/proof-1_thumb.jpg');
      expect(saved.bytes, 540);
      expect(saved.lastOpenedAt, saved.savedAt);

      store = await restart();
      expect(await store.savedProofIds(['proof-1']), {'proof-1'});
      expect(await store.usedBytes(), 540);

      await store.readThumbnail('proof-1');
      final opened = (await store.entryFor('proof-1'))!;
      expect(opened.savedAt, saved.savedAt);
      expect(opened.lastOpenedAt.isAfter(saved.lastOpenedAt), isTrue);
    });

    test('saving the same proof again replaces it without counting it twice', () async {
      final store = newStore();
      await save(store, 'attempt-1', 'proof-1', photo: 100);
      await save(store, 'attempt-1', 'proof-1', photo: 200);

      expect((await store.readPhoto('proof-1'))!.length, 200);
      expect(await store.usedBytes(), 210);
    });

    test('ids that could leave the folder are refused', () async {
      final store = newStore();
      expect(
        () => store.save(attemptId: '../x', proofId: 'p', photo: _bytes(1), thumbnail: _bytes(1)),
        throwsArgumentError,
      );
      expect(await store.readPhoto('../../etc'), isNull);
    });

    test('a file deleted from outside the app is a miss, and its entry goes away', () async {
      final store = newStore();
      await save(store, 'attempt-1', 'proof-1');
      File('${folder.path}/attempt-1/proof-1.jpg').deleteSync();

      expect(await store.readPhoto('proof-1'), isNull);
      expect(await store.entryFor('proof-1'), isNull);
    });
  });

  group('50 MB budget', () {
    test('the default budget is 50 MB', () {
      expect(kEvidenceStoreBudgetBytes, 50 * 1024 * 1024);
      expect(EvidenceStore().budgetBytes, 50 * 1024 * 1024);
    });

    test('over the budget, the photos opened longest ago go first', () async {
      final store = newStore(budgetBytes: 350);
      await save(store, 'a', 'a1'); // 110 bytes each
      await save(store, 'b', 'b1');
      await save(store, 'c', 'c1');
      // a1 is opened again: now b1 is the one opened longest ago.
      await store.readPhoto('a1');

      await save(store, 'd', 'd1');

      expect(await store.savedProofIds(['a1', 'b1', 'c1', 'd1']), {'a1', 'c1', 'd1'});
      expect(File('${folder.path}/b/b1.jpg').existsSync(), isFalse);
      expect(File('${folder.path}/b/b1_thumb.jpg').existsSync(), isFalse);
      expect(await store.usedBytes(), lessThanOrEqualTo(350));
      expect(logs.where((line) => line.contains('expulsada b1')), hasLength(1));
    });

    test('never evicts the photos of the attempt being looked at', () async {
      final store = newStore(budgetBytes: 350);
      await save(store, 'open', 'o1');
      await save(store, 'open', 'o2');
      await save(store, 'other', 'x1');
      store.markAttemptOpen('open'); // o1 and o2 are the oldest, but on screen

      await save(store, 'new', 'n1');

      expect(await store.savedProofIds(['o1', 'o2', 'x1', 'n1']), {'o1', 'o2', 'n1'});
    });

    test('the attempt being saved is protected too, even without markAttemptOpen', () async {
      final store = newStore(budgetBytes: 350);
      await save(store, 'other', 'x1');
      await save(store, 'mine', 'm1');
      await save(store, 'mine', 'm2');

      await save(store, 'mine', 'm3');

      expect(await store.savedProofIds(['x1', 'm1', 'm2', 'm3']), {'m1', 'm2', 'm3'});
    });

    test('if only the open attempt could make room, nothing is deleted and that photo is not saved', () async {
      final store = newStore(budgetBytes: 250);
      await save(store, 'open', 'o1');
      await save(store, 'open', 'o2');
      store.markAttemptOpen('open');

      final saved = await store.save(attemptId: 'other', proofId: 'x1', photo: _bytes(100), thumbnail: _bytes(10));

      expect(saved, isFalse);
      expect(await store.savedProofIds(['o1', 'o2', 'x1']), {'o1', 'o2'});
      expect(File('${folder.path}/other/x1.jpg').existsSync(), isFalse);

      store.markAttemptClosed('open');
      expect(
        await store.save(attemptId: 'other', proofId: 'x1', photo: _bytes(100), thumbnail: _bytes(10)),
        isTrue,
      );
    });

    test('saves running at the same time never overrun the budget together', () async {
      final store = newStore(budgetBytes: 350);
      await Future.wait([
        for (var i = 0; i < 6; i++)
          store.save(attemptId: 'attempt-$i', proofId: 'p$i', photo: _bytes(100), thumbnail: _bytes(10)),
      ]);

      expect(await store.usedBytes(), lessThanOrEqualTo(350));
      expect(await store.savedProofIds(['p3', 'p4', 'p5']), {'p3', 'p4', 'p5'});
    });
  });

  group('atomic writes', () {
    test('a write cut halfway leaves no photo, no .tmp and no index entry', () async {
      var failNext = false;
      final store = newStore(
        writeBytes: (file, bytes) async {
          if (failNext && file.path.endsWith('_thumb.jpg.tmp')) {
            // Half the thumbnail reaches the disk, then the "app dies".
            await file.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2), flush: true);
            throw const FileSystemException('killed mid-write');
          }
          await file.writeAsBytes(bytes, flush: true);
        },
      );
      await save(store, 'attempt-1', 'kept');

      failNext = true;
      final saved = await store.save(
        attemptId: 'attempt-1',
        proofId: 'broken',
        photo: _bytes(100),
        thumbnail: _bytes(10),
      );

      expect(saved, isFalse);
      expect(await store.entryFor('broken'), isNull);
      expect(await store.readPhoto('broken'), isNull);
      final names = Directory('${folder.path}/attempt-1').listSync().map((f) => f.uri.pathSegments.last).toSet();
      expect(names, {'kept.jpg', 'kept_thumb.jpg'});
      expect((await store.readPhoto('kept'))!.length, 100);
    });

    test('what a crash left behind is cleaned when the store opens again', () async {
      var store = newStore();
      await save(store, 'attempt-1', 'complete');
      await save(store, 'attempt-1', 'lost-file');
      // A .tmp of a write never finished, a photo written right before the
      // app died (no entry yet), and an entry whose file went away.
      File('${folder.path}/attempt-1/half.jpg.tmp').writeAsBytesSync([0xFF, 0xD8]);
      File('${folder.path}/attempt-1/orphan.jpg').writeAsBytesSync(_bytes(50));
      File('${folder.path}/attempt-1/lost-file_thumb.jpg').deleteSync();

      store = await restart();

      expect(await store.savedProofIds(['complete', 'lost-file', 'orphan', 'half']), {'complete'});
      final names = Directory('${folder.path}/attempt-1').listSync().map((f) => f.uri.pathSegments.last).toSet();
      expect(names, {'complete.jpg', 'complete_thumb.jpg'});
    });
  });

  group('sign-out', () {
    test('clear() deletes every file and the index; the store works again afterwards', () async {
      final store = newStore();
      await save(store, 'attempt-1', 'proof-1');
      await save(store, 'attempt-2', 'proof-2');

      await store.clear();

      expect(folder.existsSync(), isFalse);
      expect(await store.savedProofIds(['proof-1', 'proof-2']), isEmpty);
      expect(await store.usedBytes(), 0);
      await save(store, 'attempt-3', 'proof-3');
      expect(await store.savedProofIds(['proof-3']), {'proof-3'});
    });

    test('a save still running when clear() starts is deleted with the rest', () async {
      final store = newStore();
      final saving = store.save(attemptId: 'attempt-1', proofId: 'late', photo: _bytes(100), thumbnail: _bytes(10));
      final clearing = store.clear();
      await Future.wait([saving, clearing]);

      // Checked first: the next use of the store creates the (empty) folder again.
      expect(folder.existsSync(), isFalse);
      expect(await store.savedProofIds(['late']), isEmpty);
    });

    test('LocalDataSource.clear() (sign-out) deletes the saved evidence too', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProvider,
        (_) async => temp.path,
      );
      SharedPreferences.setMockInitialValues({});
      await Hive.close();
      final store = newStore();
      final local = LocalDataSource(evidenceStore: store);
      await local.init();
      await save(store, 'attempt-1', 'proof-1');

      await local.clear();

      expect(await store.savedProofIds(['proof-1']), isEmpty);
      expect(Directory('${folder.path}/attempt-1').existsSync(), isFalse);
    });
  });
}
