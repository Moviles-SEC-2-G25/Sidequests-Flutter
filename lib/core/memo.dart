/// Caching strategy: memoization of pure functions. A pure function gives the
/// same result for the same input, so its last result can be reused for as
/// long as the input stays the same: there's no TTL, since that result can't go
/// stale while the key doesn't change. Only one entry is kept: what changes is
/// the next input, not a set of inputs to go back to (unlike MemoryCache's LRU).
library;

/// A cache the session owns, emptied on sign-out.
abstract interface class SessionCache {
  void clear();
}

/// The last result of a pure function and the key it was computed for. Keys
/// are compared with `==`, which for a List is its identity: give it lists that
/// are only ever replaced, never modified in place.
class Memo<K, V> implements SessionCache {
  ({K key, V value})? _entry;

  /// The value stored for [key], or [compute]'s result (then stored) when the
  /// key changed or nothing was stored yet.
  V get(K key, V Function() compute) {
    final entry = _entry;
    if (entry != null && entry.key == key) return entry.value;
    final value = compute();
    _entry = (key: key, value: value);
    return value;
  }

  @override
  void clear() => _entry = null;
}

/// [Memo] for a result that takes a Future. Callers asking for the same key
/// while it's being computed share that computation; one that fails isn't
/// kept, so the next call computes again.
class AsyncMemo<K, V> implements SessionCache {
  ({K key, Future<V> value})? _entry;

  Future<V> get(K key, Future<V> Function() compute) {
    final entry = _entry;
    if (entry != null && entry.key == key) return entry.value;
    final value = compute();
    final stored = (key: key, value: value);
    _entry = stored;
    // Only forgets it: the caller still gets the error from [value].
    value.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_entry, stored)) _entry = null;
      },
    );
    return value;
  }

  @override
  void clear() => _entry = null;
}
