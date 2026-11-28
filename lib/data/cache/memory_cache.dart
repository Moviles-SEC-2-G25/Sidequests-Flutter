import '../../core/memo.dart';

/// Caching strategy (Sprint 3): a small in-memory cache in front of the
/// network, bounded in time (TTL) and in size (LRU).
///
/// - TTL: an entry older than [ttl] is a miss, so data edited on the server
///   reaches the app again after at most [ttl].
/// - LRU: past [maxEntries], the least recently used entry is dropped, so the
///   cache can't grow without limit while the user browses.
///
/// It lives only while the app runs. What has to survive a restart or work
/// offline is the Hive cache in LocalDataSource (local storage strategy),
/// which repositories still fall back to when the network fails.
///
/// A [SessionCache], so one holding account data can be emptied on sign-out.
class MemoryCache<K, V> implements SessionCache {
  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;

  // A Dart map literal is a LinkedHashMap: it keeps insertion order, so the
  // first key is always the least recently used one.
  final _entries = <K, ({V value, DateTime storedAt})>{};

  MemoryCache({required this.ttl, required this.maxEntries, DateTime Function()? now})
    : assert(maxEntries > 0),
      _now = now ?? DateTime.now;

  int get length => _entries.length;

  /// The value stored for [key], or null when it was never stored, was
  /// evicted or expired. A hit becomes the most recently used entry.
  V? get(K key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    final age = _now().difference(entry.storedAt);
    // Negative: the device clock moved back, so the real age is unknown.
    if (age.isNegative || age >= ttl) return null;
    _entries[key] = entry;
    return entry.value;
  }

  void put(K key, V value) {
    _entries.remove(key);
    _entries[key] = (value: value, storedAt: _now());
    if (_entries.length > maxEntries) _entries.remove(_entries.keys.first);
  }

  /// The value stored for [key] even if it expired ("stale-if-error": the
  /// network failed, and an old answer beats none). Doesn't count as a use.
  V? getStale(K key) => _entries[key]?.value;

  void invalidate(K key) => _entries.remove(key);

  @override
  void clear() => _entries.clear();
}
