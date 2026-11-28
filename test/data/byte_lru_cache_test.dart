import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequests/core/memo.dart';
import 'package:sidequests/data/cache/byte_lru_cache.dart';

Uint8List _bytes(int length) => Uint8List(length);

void main() {
  test('the thumbnail cache is bounded at 15 MB', () {
    expect(kEvidenceThumbnailCacheBytes, 15 * 1024 * 1024);
  });

  test('a hit returns the same bytes and counts; a miss counts too', () {
    final cache = ByteLruCache<String>(maxBytes: 100);
    final value = _bytes(10);
    cache.put('a', value);

    expect(identical(cache.get('a'), value), isTrue); // same instance: Image.memory reuses its decode
    expect(cache.get('b'), isNull);
    expect(cache.hits, 1);
    expect(cache.misses, 1);
    expect(cache.sizeBytes, 10);
  });

  test('evicts by bytes, least recently used first, as many as needed', () {
    final cache = ByteLruCache<String>(maxBytes: 100);
    cache
      ..put('a', _bytes(40))
      ..put('b', _bytes(40))
      ..put('c', _bytes(20)); // 100: full
    cache.get('a'); // a is now the most recently used

    cache.put('d', _bytes(50)); // needs 50: b (40) and then c (20) go

    expect(cache.keysLeastRecentFirst, ['a', 'd']);
    expect(cache.sizeBytes, 90);
    expect(cache.evictions, 2);
  });

  test('bounded by size, not count: one big entry can push out many small ones', () {
    final cache = ByteLruCache<String>(maxBytes: 1000);
    for (var i = 0; i < 100; i++) {
      cache.put('thumb-$i', _bytes(10));
    }
    expect(cache.length, 100);

    cache.put('photo', _bytes(950));

    expect(cache.length, 6); // the photo + the 5 most recent thumbnails
    expect(cache.sizeBytes, lessThanOrEqualTo(1000));
    expect(cache.containsKey('thumb-99'), isTrue);
    expect(cache.containsKey('thumb-94'), isFalse);
  });

  test('a value larger than the whole budget is not kept, and evicts nothing', () {
    final cache = ByteLruCache<String>(maxBytes: 100);
    cache.put('a', _bytes(50));

    expect(cache.put('huge', _bytes(101)), isFalse);
    expect(cache.containsKey('huge'), isFalse);
    expect(cache.containsKey('a'), isTrue);
  });

  test('replacing a key adjusts the size instead of adding to it', () {
    final cache = ByteLruCache<String>(maxBytes: 100);
    cache
      ..put('a', _bytes(60))
      ..put('a', _bytes(30));
    expect(cache.sizeBytes, 30);
    expect(cache.length, 1);
  });

  test('is a SessionCache: sign-out empties it', () {
    final cache = ByteLruCache<String>(maxBytes: 100)..put('a', _bytes(10));
    final SessionCache session = cache;

    session.clear();

    expect(cache.length, 0);
    expect(cache.sizeBytes, 0);
    expect(cache.get('a'), isNull);
  });
}
