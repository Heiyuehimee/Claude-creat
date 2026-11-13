import 'package:sqflite/sqflite.dart';

/// SQLite schema. Everything the user did (progress, manual organisation,
/// ignores) lives here; the comic files themselves are never modified.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const version = 1;

  static Future<AppDatabase> open(
    String path, {
    DatabaseFactory? factory,
  }) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => _create(db),
      ),
    );
    return AppDatabase._(db);
  }

  static Future<void> _create(Database db) async {
    final b = db.batch();
    b.execute('''
      CREATE TABLE roots (
        id INTEGER PRIMARY KEY,
        uri TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        last_scan_at INTEGER
      )''');
    b.execute('''
      CREATE TABLE series (
        id INTEGER PRIMARY KEY,
        auto_key TEXT UNIQUE,
        title TEXT NOT NULL,
        author TEXT,
        circle TEXT,
        confidence TEXT NOT NULL DEFAULT 'low',
        title_override TEXT,
        author_override TEXT,
        cover_item_id INTEGER,
        cover_page INTEGER,
        direction TEXT,
        manual INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )''');
    b.execute('''
      CREATE TABLE items (
        id INTEGER PRIMARY KEY,
        root_id INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        uri TEXT NOT NULL,
        is_pdf INTEGER NOT NULL,
        size INTEGER NOT NULL,
        modified INTEGER NOT NULL,
        image_count INTEGER NOT NULL DEFAULT 0,
        fingerprint TEXT,
        missing INTEGER NOT NULL DEFAULT 0,
        ignored INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        page_count INTEGER,
        cover_version INTEGER NOT NULL DEFAULT 0,
        last_page INTEGER NOT NULL DEFAULT 0,
        finished INTEGER NOT NULL DEFAULT 0,
        last_read_at INTEGER,
        series_id INTEGER REFERENCES series(id) ON DELETE SET NULL,
        manual_series INTEGER NOT NULL DEFAULT 0,
        auto_title TEXT NOT NULL DEFAULT '',
        auto_sort REAL NOT NULL DEFAULT 0,
        auto_kind INTEGER NOT NULL DEFAULT 0,
        uncertain INTEGER NOT NULL DEFAULT 0,
        confirmed INTEGER NOT NULL DEFAULT 0,
        title_override TEXT,
        number_override REAL,
        order_override REAL,
        search_text TEXT NOT NULL DEFAULT '',
        UNIQUE(root_id, path)
      )''');
    b.execute('CREATE INDEX items_series ON items(series_id)');
    b.execute('''
      CREATE TABLE ignores (
        root_id INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        PRIMARY KEY (root_id, path)
      )''');
    b.execute('''
      CREATE TABLE folder_roles (
        root_id INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        role TEXT NOT NULL,
        PRIMARY KEY (root_id, path)
      )''');
    b.execute('''
      CREATE TABLE dismissed_suggestions (
        key TEXT PRIMARY KEY
      )''');
    b.execute('''
      CREATE TABLE categories (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE
      )''');
    b.execute('''
      CREATE TABLE series_categories (
        series_id INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
        category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
        PRIMARY KEY (series_id, category_id)
      )''');
    b.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''');
    await b.commit(noResult: true);
  }

  Future<void> close() => db.close();
}
