import 'package:sqflite/sqflite.dart';

import '../../models/step_log_entry.dart';

/// Local storage strategy, relational part: every finished walk in a SQLite
/// table, so "Mis estadísticas" can ask questions Hive's key-value boxes
/// can't answer without loading everything (a sum since a date, a GROUP BY,
/// the maximum). Hive keeps the rest (step totals, the active session,
/// pending photos). Local only and per account: cleared on sign-out.
///
/// Not available on the web build (no sqflite there, and no podómetro either).
class StepLogDatabase {
  static const defaultPath = 'step_log.db';
  static const _table = 'step_log';

  final DatabaseFactory _factory;
  final String _path;
  Future<Database>? _database;

  /// [factory] is the sqflite plugin in the app and sqflite_common_ffi in
  /// tests; [path] may be `inMemoryDatabasePath`.
  StepLogDatabase({required DatabaseFactory factory, String path = defaultPath})
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
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE $_table (
            attempt_id TEXT PRIMARY KEY,
            quest_id TEXT NOT NULL,
            category TEXT,
            steps INTEGER NOT NULL CHECK (steps > 0),
            outcome TEXT NOT NULL CHECK (outcome IN ('completed', 'abandoned')),
            finished_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX ${_table}_finished_at_idx ON $_table (finished_at)');
      },
    ),
  );

  /// One row per attempt: saving it again (a retried completion) replaces it.
  Future<void> insertOrReplace(StepLogEntry entry) async {
    final db = await _db;
    await db.insert(_table, entry.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Steps of the walks finished at [since] or later; 0 when there are none.
  Future<int> stepsSince(DateTime since) async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(steps), 0) AS total FROM $_table WHERE finished_at >= ?',
      [since.toUtc().millisecondsSinceEpoch],
    );
    return rows.single['total'] as int;
  }

  /// Steps per category, most walked first. Walks whose quest had no known
  /// category are left out.
  Future<List<({String category, int steps})>> stepsByCategory() async {
    final db = await _db;
    final rows = await db.rawQuery(
      'SELECT category, SUM(steps) AS total FROM $_table '
      'WHERE category IS NOT NULL GROUP BY category ORDER BY total DESC, category ASC',
    );
    return [
      for (final row in rows) (category: row['category'] as String, steps: row['total'] as int),
    ];
  }

  /// The walk with the most steps (the latest one on a tie); null when empty.
  Future<StepLogEntry?> topWalk() async {
    final db = await _db;
    final rows = await db.query(
      _table,
      orderBy: 'steps DESC, finished_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : StepLogEntry.fromRow(rows.single);
  }

  Future<void> clear() async {
    final db = await _db;
    await db.delete(_table);
  }

  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database != null) await (await database).close();
  }
}
