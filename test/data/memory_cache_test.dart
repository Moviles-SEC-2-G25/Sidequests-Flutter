import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/data/cache/memory_cache.dart';

void main() {
  late DateTime now;
  MemoryCache<String, int> cache({int maxEntries = 3}) => MemoryCache(
    ttl: const Duration(minutes: 10),
    maxEntries: maxEntries,
    now: () => now,
  );

  setUp(() => now = DateTime(2026, 11, 23, 12));

  test('a stored value is a hit until its TTL runs out', () {
    final memory = cache()..put('a', 1);

    now = now.add(const Duration(minutes: 9, seconds: 59));
    expect(memory.get('a'), 1);

    now = now.add(const Duration(seconds: 1));
    expect(memory.get('a'), isNull);
    expect(memory.length, 0, reason: 'an expired entry is dropped');
  });

  test('storing again restarts the TTL', () {
    final memory = cache()..put('a', 1);
    now = now.add(const Duration(minutes: 8));
    memory.put('a', 2);
    now = now.add(const Duration(minutes: 8));

    expect(memory.get('a'), 2);
  });

  test('a clock that moved back counts as expired', () {
    final memory = cache()..put('a', 1);
    now = now.subtract(const Duration(minutes: 1));

    expect(memory.get('a'), isNull);
  });

  test('past maxEntries the least recently used entry is evicted', () {
    final memory = cache()
      ..put('a', 1)
      ..put('b', 2)
      ..put('c', 3);
    memory.get('a'); // 'b' is now the least recently used

    memory.put('d', 4);

    expect(memory.length, 3);
    expect(memory.get('b'), isNull);
    expect([memory.get('a'), memory.get('c'), memory.get('d')], [1, 3, 4]);
  });

  test('invalidate and clear drop entries', () {
    final memory = cache()
      ..put('a', 1)
      ..put('b', 2);

    memory.invalidate('a');
    expect(memory.get('a'), isNull);
    expect(memory.get('b'), 2);

    memory.clear();
    expect(memory.length, 0);
  });
}
