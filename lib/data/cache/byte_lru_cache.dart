import 'package:flutter/foundation.dart';

import '../../core/memo.dart';

/// Thumbnails kept in memory: ~600 of ~25 KB. Well below what Flutter's own
/// ImageCache allows for decoded images (100 MB), since these are the encoded
/// bytes and the decoded ones are counted there.
const kEvidenceThumbnailCacheBytes = 15 * 1024 * 1024;

/// Full photos kept in memory for the viewer: ~30 of the ~300 KB the app
/// captures, so swiping back and forth through an attempt never re-reads the
/// disk; a 25 MB photo from the Kotlin app is simply not kept.
const kEvidencePhotoCacheBytes = 10 * 1024 * 1024;

/// Caching strategy (Alejandro, Sprint 4): every thumbnail and photo of
/// "Evidencias de un intento" is looked up in three levels, in order
/// (EvidenceRepository):
///
/// 1. Memory: this cache. Instant, lives while the app runs.
/// 2. Disk: EvidenceStore (local storage strategy). Survives a restart and
///    works offline.
/// 3. Network: the private bucket, through NetworkGuard and the download pool.
///
/// What comes from level 2 or 3 is put in level 1, and what comes from level 3
/// is also written to level 2, so the next lookup stops as high as possible.
/// Debug counters of which level answered (memory / disk / network) are
/// printed after each lookup.
///
/// This level is an LRU bounded by BYTES, not by number of entries: a
/// thumbnail is ~25 KB, a photo ~300 KB, and one from the Kotlin app can be
/// 25 MB, so "N entries" says nothing about the memory used. Past [maxBytes]
/// the least recently used entries go first, as many as needed for the new
/// one to fit; a value larger than [maxBytes] is not kept at all (it would
/// push everything else out for a single entry).
///
/// Unlike MemoryCache (Lucas, Sprint 3; count-bounded, with a TTL, in front of
/// network data that can change on the server), there's no TTL: a proof is
/// immutable — its storage path is unique and the bucket has no UPDATE policy
/// — so a cached copy can never be stale, only evicted for space. It's emptied
/// on sign-out (SessionCache, AuthRepository): the photos are the account's.
/// When painted, the bytes are decoded with cacheWidth (ResizeImage), so a
/// thumbnail never decodes at the photo's full size. Kotlin: an
/// `LruCache<String, ByteArray>` overriding sizeOf() to return the byte count.
class ByteLruCache<K> implements SessionCache {
  final int maxBytes;

  // A map literal is a LinkedHashMap: insertion order, so the first key is
  // always the least recently used.
  final _entries = <K, Uint8List>{};
  int _sizeBytes = 0;
  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;

  ByteLruCache({required this.maxBytes}) : assert(maxBytes > 0);

  /// Bytes held right now; never more than [maxBytes].
  int get sizeBytes => _sizeBytes;
  int get length => _entries.length;
  int get hits => _hits;
  int get misses => _misses;

  /// Entries dropped to make room.
  int get evictions => _evictions;

  /// The bytes stored for [key], or null. A hit becomes the most recently used.
  Uint8List? get(K key) {
    final value = _entries.remove(key);
    if (value == null) {
      _misses++;
      return null;
    }
    _entries[key] = value;
    _hits++;
    return value;
  }

  bool containsKey(K key) => _entries.containsKey(key);

  /// Stores [value] as the most recently used entry, evicting the least
  /// recently used ones until everything fits. False (and nothing stored)
  /// when [value] alone is larger than [maxBytes].
  bool put(K key, Uint8List value) {
    remove(key);
    if (value.lengthInBytes > maxBytes) return false;
    _entries[key] = value;
    _sizeBytes += value.lengthInBytes;
    while (_sizeBytes > maxBytes) {
      final oldest = _entries.keys.first;
      _sizeBytes -= _entries.remove(oldest)!.lengthInBytes;
      _evictions++;
    }
    return true;
  }

  void remove(K key) {
    final removed = _entries.remove(key);
    if (removed != null) _sizeBytes -= removed.lengthInBytes;
  }

  @override
  void clear() {
    _entries.clear();
    _sizeBytes = 0;
  }

  @override
  String toString() =>
      'ByteLruCache(${_entries.length} entries, ${(_sizeBytes / 1024).toStringAsFixed(0)} KB '
      'of ${(maxBytes / 1024 / 1024).toStringAsFixed(0)} MB, hits $_hits, misses $_misses, '
      'evictions $_evictions)';

  @visibleForTesting
  Iterable<K> get keysLeastRecentFirst => _entries.keys;
}
