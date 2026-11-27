import 'package:sqflite/sqflite.dart';

class PendingTelemetryEvent {
  final int id;
  final String eventType;
  final String sessionId;
  final String metadataJson;
  final int createdAtMillis;

  const PendingTelemetryEvent({
    required this.id,
    required this.eventType,
    required this.sessionId,
    required this.metadataJson,
    required this.createdAtMillis,
  });
}

/// Local storage (mirror of Kotlin's TelemetryStore): SQLite queue of BQ1
/// telemetry events waiting to be uploaded.
///
/// Events are written here first, so nothing is lost offline or when the app
/// fails; Bq1Telemetry uploads and deletes them when there's a connection.
/// Bounded to [maxRows] in case the device stays offline for a long time.
class TelemetryStore {
  static const defaultPath = 'sidequests_telemetry.db';
  static const _table = 'pending_events';
  static const maxRows = 500;

  final DatabaseFactory _factory;
  final String _path;
  Future<Database>? _database;

  /// [factory] is the sqflite plugin in the app and sqflite_common_ffi in
  /// tests; [path] may be `inMemoryDatabasePath`.
  TelemetryStore({required DatabaseFactory factory, String path = defaultPath})
    : _factory = factory,
      _path = path;

  /// Opened on first use, so it never delays the app's start. A failed open
  /// is retried on the next call.
  Future<Database> get _db => _database ??= _open().catchError((Object error) {
    _database = null;
    throw error;
  });

  Future<Database> _open() => _factory.openDatabase(
    _path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE $_table (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          event_type TEXT NOT NULL,
          session_id TEXT NOT NULL,
          metadata TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      '''),
    ),
  );

  /// Insert and trim in one transaction.
  Future<int> insert({
    required String eventType,
    required String sessionId,
    required String metadataJson,
    required int createdAtMillis,
  }) async {
    final db = await _db;
    return db.transaction((txn) async {
      final id = await txn.insert(_table, {
        'event_type': eventType,
        'session_id': sessionId,
        'metadata': metadataJson,
        'created_at': createdAtMillis,
      });
      await txn.rawDelete(
        'DELETE FROM $_table WHERE id NOT IN '
        '(SELECT id FROM $_table ORDER BY id DESC LIMIT $maxRows)',
      );
      return id;
    });
  }

  Future<List<PendingTelemetryEvent>> oldest(int limit) async {
    final db = await _db;
    final rows = await db.query(_table, orderBy: 'id ASC', limit: limit);
    return [
      for (final row in rows)
        PendingTelemetryEvent(
          id: row['id'] as int,
          eventType: row['event_type'] as String,
          sessionId: row['session_id'] as String,
          metadataJson: row['metadata'] as String,
          createdAtMillis: row['created_at'] as int,
        ),
    ];
  }

  Future<void> delete(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    await db.delete(
      _table,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  Future<int> count() async {
    final db = await _db;
    return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $_table')) ?? 0;
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database != null) await (await database).close();
  }
}
