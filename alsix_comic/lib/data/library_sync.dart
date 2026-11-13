import 'package:sqflite/sqflite.dart';

import '../core/recognition/library_recognizer.dart';
import '../core/recognition/text_utils.dart';
import '../platform/native_bridge.dart';
import 'database.dart';

/// Counts reported after a scan.
class SyncReport {
  int added = 0;
  int removed = 0;
  int moved = 0;
  int modified = 0;
  int restored = 0;
  int total = 0;
  int pending = 0;

  bool get hasChanges => added + removed + moved + modified + restored > 0;
}

/// Brings the database in line with the files on disk.
///
/// Rules: rows are never deleted when a file disappears (it is marked missing
/// and comes back with its history when the file returns); moved or renamed
/// files keep their row; manual decisions are never overwritten.
class LibrarySync {
  LibrarySync(this.database, this.native);

  final AppDatabase database;
  final NativeBridge native;

  Database get _db => database.db;

  /// Scans every root and re-runs recognition.
  Future<SyncReport> syncAll({void Function(ScanProgress)? progress}) async {
    final report = SyncReport();
    final roots = await _db.query('roots');
    var offset = 0;
    for (final root in roots) {
      final rootId = root['id'] as int;
      List<ScannedEntry> scanned;
      try {
        scanned = await native.scan(
          root['uri'] as String,
          progress: progress == null
              ? null
              : (p) => progress(ScanProgress(offset + p.count, p.dir)),
        );
      } catch (_) {
        // Permission revoked or storage unmounted: keep everything as is.
        continue;
      }
      offset += scanned.length;
      await applyScan(rootId, scanned, report);
      await _db.update(
        'roots',
        {'last_scan_at': _now()},
        where: 'id = ?',
        whereArgs: [rootId],
      );
    }
    await recognize(report);
    return report;
  }

  /// Reconciles one root's scan result with its stored items.
  Future<void> applyScan(
    int rootId,
    List<ScannedEntry> scanned,
    SyncReport report,
  ) async {
    final ignores = (await _db.query(
      'ignores',
      where: 'root_id = ?',
      whereArgs: [rootId],
    )).map((r) => r['path'] as String).toList();
    bool isIgnored(String path) =>
        ignores.any((i) => path == i || path.startsWith('$i/'));

    final rows = await _db.query(
      'items',
      where: 'root_id = ?',
      whereArgs: [rootId],
    );
    final byPath = {for (final r in rows) r['path'] as String: r};
    final seen = <String>{};
    final added = <ScannedEntry>[];
    final batch = _db.batch();

    for (final e in scanned) {
      if (isIgnored(e.path)) continue;
      seen.add(e.path);
      final row = byPath[e.path];
      if (row == null) {
        added.add(e);
        continue;
      }
      final changed =
          row['size'] != e.size ||
          row['modified'] != e.modified ||
          row['image_count'] != e.imageCount;
      if (row['missing'] == 1) report.restored++;
      if (changed) report.modified++;
      batch.update(
        'items',
        {
          'uri': e.uri,
          'size': e.size,
          'modified': e.modified,
          'image_count': e.imageCount,
          'missing': 0,
          if (changed) 'page_count': null,
          if (changed) 'fingerprint': null,
          if (changed) 'cover_version': (row['cover_version'] as int) + 1,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }

    // Rows whose file disappeared: maybe moved/renamed, otherwise missing.
    final gone = [
      for (final r in rows)
        if (!seen.contains(r['path']) &&
            r['missing'] == 0 &&
            !isIgnored(r['path'] as String))
          r,
    ];
    final movedTo = await _matchMoves(gone, added);
    for (final MapEntry(key: row, value: e) in movedTo.entries) {
      report.moved++;
      added.remove(e);
      gone.remove(row);
      batch.update(
        'items',
        {
          'path': e.path,
          'uri': e.uri,
          'size': e.size,
          'modified': e.modified,
          'image_count': e.imageCount,
          'missing': 0,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    for (final r in gone) {
      report.removed++;
      batch.update(
        'items',
        {'missing': 1},
        where: 'id = ?',
        whereArgs: [r['id']],
      );
    }
    final now = _now();
    for (final e in added) {
      report.added++;
      batch.insert('items', {
        'root_id': rootId,
        'path': e.path,
        'uri': e.uri,
        'is_pdf': e.isPdf ? 1 : 0,
        'size': e.size,
        'modified': e.modified,
        'image_count': e.imageCount,
        'added_at': now,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Pairs disappeared rows with new entries that are the same file.
  Future<Map<Map<String, Object?>, ScannedEntry>> _matchMoves(
    List<Map<String, Object?>> gone,
    List<ScannedEntry> added,
  ) async {
    final result = <Map<String, Object?>, ScannedEntry>{};
    if (gone.isEmpty || added.isEmpty) return result;
    final free = List<ScannedEntry>.of(added);
    String base(String path) => path.split('/').last;
    for (final row in gone) {
      final isPdf = row['is_pdf'] == 1;
      final candidates = free
          .where(
            (e) =>
                e.isPdf == isPdf &&
                e.size == row['size'] &&
                (isPdf || e.imageCount == row['image_count']),
          )
          .toList();
      if (candidates.isEmpty) continue;
      // Same file name in another folder: a plain move.
      final sameName = candidates
          .where((e) => base(e.path) == base(row['path'] as String))
          .toList();
      ScannedEntry? match;
      if (sameName.length == 1) {
        match = sameName.single;
      } else if (isPdf) {
        // Renamed: compare content fingerprints.
        final known = row['fingerprint'] as String?;
        if (known != null) {
          for (final c in candidates) {
            try {
              if (await native.fingerprint(c.uri) == known) {
                match = c;
                break;
              }
            } catch (_) {}
          }
        }
      } else if (candidates.length == 1) {
        match = candidates.single;
      }
      if (match != null) {
        result[row] = match;
        free.remove(match);
      }
    }
    return result;
  }

  /// Computes fingerprints for PDFs that have none, so later renames can be
  /// recognised. Runs in the background after a scan.
  Future<void> fillFingerprints({int limit = 200}) async {
    final rows = await _db.query(
      'items',
      columns: ['id', 'uri'],
      where: 'fingerprint IS NULL AND is_pdf = 1 AND missing = 0',
      limit: limit,
    );
    for (final r in rows) {
      try {
        final fp = await native.fingerprint(r['uri'] as String);
        await _db.update(
          'items',
          {'fingerprint': fp},
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      } catch (_) {}
    }
  }

  /// Runs the recognition engine over every present item and stores the
  /// result, respecting manual series assignments.
  Future<void> recognize(SyncReport report) async {
    final roots = await _db.query('roots');
    final rootNames = {
      for (final r in roots) r['id'] as int: r['name'] as String,
    };
    final rows = await _db.query('items', where: 'missing = 0 AND ignored = 0');
    report.total = rows.length;

    String key(Map<String, Object?> r) => '#${r['root_id']}/${r['path']}';
    final rowByKey = {for (final r in rows) key(r): r};
    final roles = {
      for (final r in await _db.query('folder_roles'))
        '#${r['root_id']}/${r['path']}': r['role'] == 'series'
            ? FolderRole.series
            : FolderRole.category,
    };

    final result = recognizeLibrary([
      for (final r in rows)
        LibraryEntry(
          key(r),
          r['is_pdf'] == 1 ? EntryType.pdf : EntryType.imageFolder,
        ),
    ], folderRoles: roles);

    final existing = await _db.query('series');
    final byAutoKey = {
      for (final s in existing)
        if (s['auto_key'] != null) s['auto_key'] as String: s,
    };
    final producedKeys = result.series.map((s) => s.id).toSet();
    final now = _now();
    final autoIdForKey = <String, int>{};

    await _db.transaction((txn) async {
      // Updates are batched; only inserts need an immediate round trip.
      final b = txn.batch();
      for (final rs in result.series) {
        final values = {
          'title': rs.title,
          'author': rs.author,
          'circle': rs.circle,
          'confidence': rs.confidence.name,
        };
        var row = byAutoKey[rs.id];
        int id;
        if (row != null) {
          id = row['id'] as int;
          if (row['title'] != rs.title ||
              row['author'] != rs.author ||
              row['circle'] != rs.circle ||
              row['confidence'] != rs.confidence.name) {
            b.update('series', values, where: 'id = ?', whereArgs: [id]);
          }
        } else {
          // Reuse the previous series row of these chapters when that series
          // is no longer produced, so its manual title/cover/direction survive.
          final previous = rs.chapters
              .map((c) => rowByKey[c.entry.path]!['series_id'] as int?)
              .whereType<int>()
              .toSet();
          final reusable = existing.where(
            (s) =>
                previous.contains(s['id']) &&
                s['manual'] == 0 &&
                s['auto_key'] != null &&
                !producedKeys.contains(s['auto_key']) &&
                !autoIdForKey.containsValue(s['id']),
          );
          if (reusable.isNotEmpty) {
            id = reusable.first['id'] as int;
            b.update(
              'series',
              {...values, 'auto_key': rs.id},
              where: 'id = ?',
              whereArgs: [id],
            );
          } else {
            id = await txn.insert('series', {
              ...values,
              'auto_key': rs.id,
              'created_at': now,
            });
          }
        }
        autoIdForKey[rs.id] = id;

        for (final c in rs.chapters) {
          final item = rowByKey[c.entry.path]!;
          final parsed = c.parsed;
          final values = <String, Object?>{
            if (item['manual_series'] == 0) 'series_id': id,
            'auto_title': parsed.title,
            'auto_sort': c.sortNumber.isFinite ? c.sortNumber : 1e9,
            'auto_kind': c.kind.index,
            'uncertain': c.uncertain ? 1 : 0,
            'search_text': _searchText(item['path'] as String, parsed.raw, [
              parsed.title,
              parsed.seriesTitle,
              ...parsed.authors,
              if (parsed.circle != null) parsed.circle!,
              if (parsed.source != null) parsed.source!,
              rootNames[item['root_id']] ?? '',
            ]),
          };
          if (values.entries.any((e) => item[e.key] != e.value)) {
            b.update('items', values, where: 'id = ?', whereArgs: [item['id']]);
          }
        }
      }

      // Auto series nobody points to any more.
      b.rawDelete(
        '''
        DELETE FROM series WHERE manual = 0
          AND id NOT IN (SELECT series_id FROM items WHERE series_id IS NOT NULL)''',
      );

      // Remember suggestions in terms of database series ids.
      b.delete('settings', where: 'key = ?', whereArgs: ['suggestions']);
      final lines = <String>[];
      for (final s in result.suggestions) {
        final ids =
            s.seriesIds
                .map((k) => autoIdForKey[k])
                .whereType<int>()
                .toSet()
                .toList()
              ..sort();
        if (ids.length < 2) continue;
        lines.add('${ids.join(',')}\t${s.reason}');
      }
      b.insert('settings', {'key': 'suggestions', 'value': lines.join('\n')});
      await b.commit(noResult: true);
    });
    report.pending = result.suggestions.length;
  }

  static String _searchText(String path, String raw, List<String> parts) {
    final words = <String>{normalizeLoose(raw), normalizeLoose(path)};
    for (final p in parts) {
      if (p.isNotEmpty) words.add(normalizeLoose(p));
    }
    return words.join('\n');
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}
