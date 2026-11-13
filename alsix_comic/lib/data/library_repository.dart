import 'package:sqflite/sqflite.dart';

import 'database.dart';

/// Reading direction inside the reader.
enum ReadingDirection { leftToRight, rightToLeft }

class ChapterView {
  ChapterView.fromRow(Map<String, Object?> r)
    : id = r['id'] as int,
      rootId = r['root_id'] as int,
      seriesId = r['series_id'] as int?,
      path = r['path'] as String,
      uri = r['uri'] as String,
      isPdf = r['is_pdf'] == 1,
      size = r['size'] as int,
      imageCount = r['image_count'] as int,
      missing = r['missing'] == 1,
      addedAt = r['added_at'] as int,
      pageCount = r['page_count'] as int?,
      coverVersion = r['cover_version'] as int,
      lastPage = r['last_page'] as int,
      finished = r['finished'] == 1,
      lastReadAt = r['last_read_at'] as int?,
      manualSeries = r['manual_series'] == 1,
      autoTitle = r['auto_title'] as String,
      autoSort = (r['auto_sort'] as num).toDouble(),
      autoKind = r['auto_kind'] as int,
      uncertain = r['uncertain'] == 1,
      confirmed = r['confirmed'] == 1,
      titleOverride = r['title_override'] as String?,
      numberOverride = (r['number_override'] as num?)?.toDouble(),
      orderOverride = (r['order_override'] as num?)?.toDouble(),
      searchText = r['search_text'] as String;

  final int id;
  final int rootId;
  final int? seriesId;
  final String path;
  final String uri;
  final bool isPdf;
  final int size;
  final int imageCount;
  final bool missing;
  final int addedAt;
  final int? pageCount;
  final int coverVersion;
  final int lastPage;
  final bool finished;
  final int? lastReadAt;
  final bool manualSeries;
  final String autoTitle;
  final double autoSort;
  final int autoKind;
  final bool uncertain;
  final bool confirmed;
  final String? titleOverride;
  final double? numberOverride;
  final double? orderOverride;
  final String searchText;

  String get title =>
      titleOverride ?? (autoTitle.isEmpty ? fileName : autoTitle);
  String get fileName => path.split('/').last;
  String get folder {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }

  double get order => orderOverride ?? numberOverride ?? autoSort;
  bool get started => lastReadAt != null;
  bool get needsConfirmation => uncertain && !confirmed;

  /// Known page count: from the reader, or the image count of a folder.
  int? get pages => pageCount ?? (isPdf ? null : imageCount);

  double get progress {
    if (finished) return 1;
    final p = pages;
    if (p == null || p == 0 || lastReadAt == null) return 0;
    return ((lastPage + 1) / p).clamp(0, 1).toDouble();
  }
}

class SeriesView {
  SeriesView(this.row, this.chapters, this.categoryIds);

  final Map<String, Object?> row;

  /// Chapters in reading order (missing files included, flagged).
  final List<ChapterView> chapters;
  final Set<int> categoryIds;

  int get id => row['id'] as int;
  String get title =>
      (row['title_override'] as String?) ?? row['title'] as String;
  String? get author =>
      (row['author_override'] as String?) ?? row['author'] as String?;
  String? get circle => row['circle'] as String?;
  String get confidence => row['confidence'] as String;
  bool get manual => row['manual'] == 1;
  bool get titleLocked => row['title_override'] != null;
  int? get coverItemId => row['cover_item_id'] as int?;
  int get coverPage => (row['cover_page'] as int?) ?? 0;
  int get createdAt => row['created_at'] as int;
  ReadingDirection? get direction => switch (row['direction']) {
    'rtl' => ReadingDirection.rightToLeft,
    'ltr' => ReadingDirection.leftToRight,
    _ => null,
  };

  List<ChapterView> get present => [
    for (final c in chapters)
      if (!c.missing) c,
  ];
  int get chapterCount => present.length;
  int get finishedCount => present.where((c) => c.finished).length;
  bool get allMissing => present.isEmpty;

  int? get lastReadAt {
    int? best;
    for (final c in chapters) {
      final t = c.lastReadAt;
      if (t != null && (best == null || t > best)) best = t;
    }
    return best;
  }

  int get addedAt =>
      chapters.map((c) => c.addedAt).fold(0, (a, b) => a > b ? a : b);
  bool get unread => present.every((c) => !c.started);
  bool get fullyRead => present.isNotEmpty && present.every((c) => c.finished);

  /// A chapter was added after the series was last read.
  bool get hasNewChapter {
    final last = lastReadAt;
    if (last == null) return false;
    return present.any((c) => !c.started && c.addedAt > last);
  }

  double get progress => chapterCount == 0
      ? 0
      : present.map((c) => c.progress).fold(0.0, (a, b) => a + b) /
            chapterCount;

  bool get hasPdf => present.any((c) => c.isPdf);
  bool get hasImages => present.any((c) => !c.isPdf);
  bool get needsConfirmation => present.any((c) => c.needsConfirmation);

  /// The chapter to open when the user taps "continue".
  ChapterView? get continueChapter {
    final list = present;
    if (list.isEmpty) return null;
    ChapterView? lastRead;
    for (final c in list) {
      if (c.lastReadAt != null &&
          (lastRead == null || c.lastReadAt! > lastRead.lastReadAt!)) {
        lastRead = c;
      }
    }
    if (lastRead == null) return list.first;
    if (!lastRead.finished) return lastRead;
    final i = list.indexOf(lastRead);
    return i + 1 < list.length ? list[i + 1] : lastRead;
  }

  ChapterView? get coverChapter {
    final id = coverItemId;
    if (id != null) {
      for (final c in chapters) {
        if (c.id == id && !c.missing) return c;
      }
    }
    return present.isEmpty ? null : present.first;
  }

  Set<String> get folders => {
    for (final c in present) '${c.rootId}/${c.folder}',
  };
}

class Suggestion {
  Suggestion(this.seriesIds, this.reason);
  final List<int> seriesIds;
  final String reason;
  String get key => seriesIds.join(',');
}

class RootView {
  RootView(this.id, this.uri, this.name, this.lastScanAt);
  final int id;
  final String uri;
  final String name;
  final int? lastScanAt;
}

class Category {
  Category(this.id, this.name);
  final int id;
  final String name;
}

class LibrarySnapshot {
  LibrarySnapshot({
    required this.series,
    required this.suggestions,
    required this.roots,
    required this.categories,
    required this.ignores,
    required this.folderRoles,
  });

  final List<SeriesView> series;
  final List<Suggestion> suggestions;
  final List<RootView> roots;
  final List<Category> categories;

  /// (rootId, path) of ignored folders and items.
  final List<(int, String)> ignores;
  final Map<(int, String), String> folderRoles;

  late final Map<int, SeriesView> byId = {for (final s in series) s.id: s};

  SeriesView? seriesOfChapter(int itemId) {
    for (final s in series) {
      if (s.chapters.any((c) => c.id == itemId)) return s;
    }
    return null;
  }
}

/// Reads and edits the library database.
class LibraryRepository {
  LibraryRepository(this.database);

  final AppDatabase database;
  Database get _db => database.db;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<LibrarySnapshot> load() async {
    final seriesRows = await _db.query('series');
    final itemRows = await _db.query('items', where: 'ignored = 0');
    final catRows = await _db.query('series_categories');
    final byId = <int, List<ChapterView>>{};
    for (final r in itemRows) {
      final c = ChapterView.fromRow(r);
      if (c.seriesId == null) continue;
      byId.putIfAbsent(c.seriesId!, () => []).add(c);
    }
    final cats = <int, Set<int>>{};
    for (final r in catRows) {
      cats
          .putIfAbsent(r['series_id'] as int, () => {})
          .add(r['category_id'] as int);
    }
    final series = <SeriesView>[];
    for (final r in seriesRows) {
      final chapters = byId[r['id']] ?? [];
      if (chapters.isEmpty) continue;
      chapters.sort((a, b) {
        final k = a.autoKind.compareTo(b.autoKind);
        if (k != 0 && a.orderOverride == null && b.orderOverride == null) {
          return k;
        }
        final o = a.order.compareTo(b.order);
        if (o != 0) return o;
        return a.path.compareTo(b.path);
      });
      series.add(SeriesView(r, chapters, cats[r['id']] ?? {}));
    }

    final dismissed = {
      for (final r in await _db.query('dismissed_suggestions'))
        r['key'] as String,
    };
    final suggestionText =
        (await _db.query(
              'settings',
              where: 'key = ?',
              whereArgs: ['suggestions'],
            )).firstOrNull?['value']
            as String?;
    final live = {for (final s in series) s.id};
    final suggestions = <Suggestion>[];
    for (final line in (suggestionText ?? '').split('\n')) {
      if (line.isEmpty) continue;
      final [ids, reason] = line.split('\t');
      final list = ids.split(',').map(int.parse).where(live.contains).toList();
      if (list.length < 2) continue;
      final s = Suggestion(list, reason);
      if (!dismissed.contains(s.key)) suggestions.add(s);
    }

    final roots = [
      for (final r in await _db.query('roots', orderBy: 'added_at'))
        RootView(
          r['id'] as int,
          r['uri'] as String,
          r['name'] as String,
          r['last_scan_at'] as int?,
        ),
    ];
    final categories = [
      for (final r in await _db.query('categories', orderBy: 'name'))
        Category(r['id'] as int, r['name'] as String),
    ];
    final ignores = <(int, String)>[
      for (final r in await _db.query('ignores'))
        (r['root_id'] as int, r['path'] as String),
      for (final r in await _db.query(
        'items',
        columns: ['root_id', 'path'],
        where: 'ignored = 1',
      ))
        (r['root_id'] as int, r['path'] as String),
    ];
    final roles = {
      for (final r in await _db.query('folder_roles'))
        (r['root_id'] as int, r['path'] as String): r['role'] as String,
    };
    return LibrarySnapshot(
      series: series,
      suggestions: suggestions,
      roots: roots,
      categories: categories,
      ignores: ignores,
      folderRoles: roles,
    );
  }

  // ---- Roots ---------------------------------------------------------------

  Future<int> addRoot(String uri, String name) async {
    final existing = await _db.query(
      'roots',
      where: 'uri = ?',
      whereArgs: [uri],
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;
    return _db.insert('roots', {'uri': uri, 'name': name, 'added_at': _now()});
  }

  /// Removes a root and everything recorded about its files.
  Future<void> removeRoot(int id) async {
    await _db.delete('roots', where: 'id = ?', whereArgs: [id]);
    await _db.rawDelete('''
      DELETE FROM series WHERE id NOT IN
        (SELECT series_id FROM items WHERE series_id IS NOT NULL)''');
  }

  // ---- Reading progress -----------------------------------------------------

  Future<void> saveProgress(
    int itemId, {
    required int page,
    required int pageCount,
  }) async {
    final finished = page >= pageCount - 1;
    await _db.rawUpdate(
      '''
      UPDATE items SET last_page = ?, page_count = ?, last_read_at = ?,
        finished = CASE WHEN ? THEN 1 ELSE finished END
      WHERE id = ?''',
      [page, pageCount, _now(), finished ? 1 : 0, itemId],
    );
  }

  Future<void> setPageCount(int itemId, int pageCount) => _db.update(
    'items',
    {'page_count': pageCount},
    where: 'id = ?',
    whereArgs: [itemId],
  );

  Future<void> setFinished(List<int> itemIds, bool finished) => _db.rawUpdate(
    'UPDATE items SET finished = ?, last_read_at = COALESCE(last_read_at, ?) '
    'WHERE id IN (${_marks(itemIds)})',
    [finished ? 1 : 0, _now(), ...itemIds],
  );

  Future<void> resetProgress(List<int> itemIds) => _db.rawUpdate(
    'UPDATE items SET finished = 0, last_page = 0, last_read_at = NULL '
    'WHERE id IN (${_marks(itemIds)})',
    itemIds,
  );

  // ---- Series edits (all manual edits are locked by nature) -----------------

  Future<void> renameSeries(int id, String? title) => _db.update(
    'series',
    {'title_override': _blankToNull(title)},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> setSeriesAuthor(int id, String? author) => _db.update(
    'series',
    {'author_override': _blankToNull(author)},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> setCover(int seriesId, int itemId, int page) => _db.update(
    'series',
    {'cover_item_id': itemId, 'cover_page': page},
    where: 'id = ?',
    whereArgs: [seriesId],
  );

  Future<void> setDirection(int seriesId, ReadingDirection? d) => _db.update(
    'series',
    {
      'direction': switch (d) {
        ReadingDirection.rightToLeft => 'rtl',
        ReadingDirection.leftToRight => 'ltr',
        null => null,
      },
    },
    where: 'id = ?',
    whereArgs: [seriesId],
  );

  /// Moves chapters into [seriesId]; the assignment is kept on rescans.
  Future<void> moveChapters(List<int> itemIds, int seriesId) => _db.rawUpdate(
    'UPDATE items SET series_id = ?, manual_series = 1, confirmed = 1 '
    'WHERE id IN (${_marks(itemIds)})',
    [seriesId, ...itemIds],
  );

  /// Merges [sourceIds] into [targetId].
  Future<void> mergeSeries(List<int> sourceIds, int targetId) async {
    await _db.transaction((txn) async {
      final sources = sourceIds.where((s) => s != targetId).toList();
      if (sources.isEmpty) return;
      await txn.rawUpdate(
        'UPDATE items SET series_id = ?, manual_series = 1 WHERE series_id IN (${_marks(sources)})',
        [targetId, ...sources],
      );
      // Pin the chapters already in the target so a rescan cannot split them.
      await txn.rawUpdate(
        'UPDATE items SET manual_series = 1 WHERE series_id = ?',
        [targetId],
      );
      await txn.update(
        'series',
        {'manual': 1},
        where: 'id = ?',
        whereArgs: [targetId],
      );
      await txn.rawDelete(
        'DELETE FROM series WHERE id IN (${_marks(sources)})',
        sources,
      );
    });
  }

  /// Creates a new series from some chapters of another one.
  Future<int> splitSeries(List<int> itemIds, String title) async {
    return _db.transaction((txn) async {
      final id = await txn.insert('series', {
        'title': title,
        'title_override': title,
        'manual': 1,
        'confidence': 'high',
        'created_at': _now(),
      });
      await txn.rawUpdate(
        'UPDATE items SET series_id = ?, manual_series = 1, confirmed = 1 '
        'WHERE id IN (${_marks(itemIds)})',
        [id, ...itemIds],
      );
      return id;
    });
  }

  /// Lets automatic recognition decide again for these chapters.
  Future<void> releaseChapters(List<int> itemIds) => _db.rawUpdate(
    'UPDATE items SET manual_series = 0 WHERE id IN (${_marks(itemIds)})',
    itemIds,
  );

  // ---- Chapter edits ---------------------------------------------------------

  Future<void> renameChapter(int itemId, String? title) => _db.update(
    'items',
    {'title_override': _blankToNull(title)},
    where: 'id = ?',
    whereArgs: [itemId],
  );

  Future<void> setChapterNumber(int itemId, double? number) => _db.update(
    'items',
    {'number_override': number, 'order_override': null, 'confirmed': 1},
    where: 'id = ?',
    whereArgs: [itemId],
  );

  /// Stores an explicit order for the whole series.
  Future<void> reorderChapters(List<int> orderedItemIds) async {
    final b = _db.batch();
    for (var i = 0; i < orderedItemIds.length; i++) {
      b.update(
        'items',
        {'order_override': i.toDouble(), 'confirmed': 1},
        where: 'id = ?',
        whereArgs: [orderedItemIds[i]],
      );
    }
    await b.commit(noResult: true);
  }

  Future<void> confirmChapters(List<int> itemIds) => _db.rawUpdate(
    'UPDATE items SET confirmed = 1 WHERE id IN (${_marks(itemIds)})',
    itemIds,
  );

  // ---- Ignore and folder roles ---------------------------------------------------

  Future<void> ignoreItem(int itemId) =>
      _db.update('items', {'ignored': 1}, where: 'id = ?', whereArgs: [itemId]);

  Future<void> ignoreFolder(int rootId, String path) async {
    await _db.insert('ignores', {
      'root_id': rootId,
      'path': path,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _db.rawUpdate(
      "UPDATE items SET ignored = 1 WHERE root_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\')",
      [rootId, path, '${_escapeLike(path)}/%'],
    );
  }

  Future<void> unignore(int rootId, String path) async {
    await _db.delete(
      'ignores',
      where: 'root_id = ? AND path = ?',
      whereArgs: [rootId, path],
    );
    await _db.rawUpdate(
      "UPDATE items SET ignored = 0 WHERE root_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\')",
      [rootId, path, '${_escapeLike(path)}/%'],
    );
  }

  /// [role] is 'series', 'category' or null to go back to automatic.
  Future<void> setFolderRole(int rootId, String path, String? role) async {
    if (role == null) {
      await _db.delete(
        'folder_roles',
        where: 'root_id = ? AND path = ?',
        whereArgs: [rootId, path],
      );
    } else {
      await _db.insert('folder_roles', {
        'root_id': rootId,
        'path': path,
        'role': role,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // Let the recognizer re-place the chapters of that folder.
    await _db.rawUpdate(
      "UPDATE items SET manual_series = 0 WHERE root_id = ? AND path LIKE ? ESCAPE '\\'",
      [rootId, '${_escapeLike(path)}/%'],
    );
  }

  // ---- Suggestions -------------------------------------------------------------

  Future<void> dismissSuggestion(Suggestion s) => _db.insert(
    'dismissed_suggestions',
    {'key': s.key},
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  /// Merges everything into the series with the most chapters.
  Future<int> acceptSuggestion(LibrarySnapshot snap, Suggestion s) async {
    final series =
        [for (final id in s.seriesIds) snap.byId[id]]
            .whereType<SeriesView>()
            .toList()
          ..sort((a, b) => b.chapterCount.compareTo(a.chapterCount));
    final target = series.first.id;
    await mergeSeries([for (final x in series) x.id], target);
    return target;
  }

  // ---- Categories --------------------------------------------------------------------

  Future<int> createCategory(String name) => _db.insert('categories', {
    'name': name.trim(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> deleteCategory(int id) =>
      _db.delete('categories', where: 'id = ?', whereArgs: [id]);

  Future<void> renameCategory(int id, String name) => _db.update(
    'categories',
    {'name': name.trim()},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> setSeriesCategories(int seriesId, Set<int> categoryIds) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'series_categories',
        where: 'series_id = ?',
        whereArgs: [seriesId],
      );
      for (final c in categoryIds) {
        await txn.insert('series_categories', {
          'series_id': seriesId,
          'category_id': c,
        });
      }
    });
  }

  // ---- Settings -------------------------------------------------------------------------

  Future<String?> getSetting(String key) async =>
      (await _db.query(
            'settings',
            where: 'key = ?',
            whereArgs: [key],
          )).firstOrNull?['value']
          as String?;

  Future<void> setSetting(String key, String value) => _db.insert('settings', {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  static String _marks(List<Object> values) =>
      List.filled(values.length, '?').join(',');
  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
  static String _escapeLike(String s) =>
      s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
}
