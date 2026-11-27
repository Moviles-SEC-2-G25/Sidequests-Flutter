import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/memo.dart';

void main() {
  group('Memo', () {
    late Memo<Object, int> memo;
    late int computed;

    int compute() => ++computed;

    setUp(() {
      memo = Memo();
      computed = 0;
    });

    test('same key: computed once, then served from the cache', () {
      expect(memo.get('k', compute), 1);
      expect(memo.get('k', compute), 1);
      expect(computed, 1);
    });

    test('a new key computes again and replaces the only entry', () {
      memo.get('a', compute);
      expect(memo.get('b', compute), 2);
      expect(memo.get('a', compute), 3); // 'a' was not kept: one entry only
      expect(computed, 3);
    });

    test('lists are keys by identity: a replaced list misses, the same object hits', () {
      final list = [1, 2];
      memo.get((list, list), compute);

      expect(memo.get((list, list), compute), 1);
      expect(memo.get(([1, 2], list), compute), 2); // equal contents, new object
    });

    test('clear forgets the entry', () {
      memo.get('k', compute);
      memo.clear();

      expect(memo.get('k', compute), 2);
    });

    test('a null result is a stored result too', () {
      final nullable = Memo<String, int?>();
      var calls = 0;

      nullable.get('k', () { calls++; return null; });
      nullable.get('k', () { calls++; return null; });

      expect(calls, 1);
    });
  });

  group('AsyncMemo', () {
    late AsyncMemo<String, int> memo;
    late int computed;

    Future<int> compute() async => ++computed;

    setUp(() {
      memo = AsyncMemo();
      computed = 0;
    });

    test('same key: computed once', () async {
      expect(await memo.get('k', compute), 1);
      expect(await memo.get('k', compute), 1);
      expect(computed, 1);
    });

    test('a new key computes again', () async {
      await memo.get('a', compute);
      expect(await memo.get('b', compute), 2);
    });

    test('callers arriving while it computes share that computation', () async {
      final gate = Completer<int>();
      var calls = 0;
      Future<int> slow() {
        calls++;
        return gate.future;
      }

      final first = memo.get('k', slow);
      final second = memo.get('k', slow);
      gate.complete(7);

      expect(await first, 7);
      expect(await second, 7);
      expect(calls, 1);
    });

    test('a failed computation is not kept: the next call computes again', () async {
      await expectLater(memo.get('k', () async => throw StateError('boom')), throwsStateError);

      expect(await memo.get('k', compute), 1);
    });

    test('a failure of an older key does not drop a newer entry', () async {
      final failing = Completer<int>();
      final old = memo.get('old', () => failing.future);
      await memo.get('new', compute);

      failing.completeError(StateError('late'));
      await expectLater(old, throwsStateError);

      expect(await memo.get('new', compute), 1); // still cached
    });

    test('clear forgets the entry', () async {
      await memo.get('k', compute);
      memo.clear();

      expect(await memo.get('k', compute), 2);
    });
  });
}
