import 'dart:math' as math;

import 'text_utils.dart';
import 'title_parser.dart';

/// Type of a readable item found by the scanner.
enum EntryType { pdf, imageFolder }

/// One readable item: a PDF file or a folder of images.
class LibraryEntry {
  const LibraryEntry(this.path, this.type);

  /// Path relative to the library root, '/' separated, including extension.
  final String path;
  final EntryType type;

  String get name {
    final last = path.split('/').last;
    return type == EntryType.pdf
        ? last.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')
        : last;
  }

  String get dir {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }
}

enum Confidence { high, medium, low }

/// Manual folder role set by the user.
enum FolderRole {
  /// Everything inside the folder is one series named after the folder.
  series,

  /// A plain category: never turned into a series automatically.
  category,
}

class RecognizedChapter {
  RecognizedChapter({
    required this.entry,
    required this.parsed,
    required this.sortNumber,
    required this.kind,
    this.uncertain = false,
  });

  final LibraryEntry entry;
  final ParsedTitle parsed;

  /// Number used for ordering (implicit numbers already applied).
  final double sortNumber;
  final ChapterKind kind;

  /// The engine could not place this chapter reliably: show it in 待确认.
  final bool uncertain;

  String get displayTitle => parsed.title;
}

class RecognizedSeries {
  RecognizedSeries({
    required this.id,
    required this.title,
    required this.chapters,
    required this.confidence,
    this.author,
    this.circle,
    this.folder,
  });

  /// Stable identifier derived from what the series was built from.
  final String id;
  final String title;
  final String? author;
  final String? circle;
  final List<RecognizedChapter> chapters;
  final Confidence confidence;

  /// Set when the series was built from a "series folder".
  final String? folder;

  bool get hasUncertainChapter => chapters.any((c) => c.uncertain);
}

/// A medium-confidence proposal: these series probably belong together.
class MergeSuggestion {
  MergeSuggestion(this.seriesIds, this.reason);
  final List<String> seriesIds;
  final String reason;
}

class RecognitionResult {
  RecognitionResult(this.series, this.suggestions);
  final List<RecognizedSeries> series;
  final List<MergeSuggestion> suggestions;

  RecognizedSeries? seriesOf(String path) {
    for (final s in series) {
      if (s.chapters.any((c) => c.entry.path == path)) return s;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------

class _Item {
  _Item(this.entry, this.name, this.groupDir)
    : parsed = parseTitle(name).inheritAuthors(_folderAuthors(entry.dir));
  final LibraryEntry entry;

  /// Name used for recognition (may be the wrapper folder name).
  final String name;

  /// Directory used for folder-role decisions (wrapper folders collapsed).
  final String groupDir;
  final ParsedTitle parsed;
}

final _folderAuthorCache = <String, List<String>>{};

/// Authors named by the nearest folder written like "[Midnight] 合集分散".
List<String> _folderAuthors(String dir) {
  return _folderAuthorCache.putIfAbsent(dir, () {
    var d = dir;
    while (d.isNotEmpty) {
      final name = _dirName(d);
      if (RegExp(r'^\s*[\[【(]').hasMatch(name)) {
        final p = parseTitle(name);
        if (p.authors.isNotEmpty) return p.authors;
      }
      d = _parentDir(d);
    }
    return const [];
  });
}

final _codeName = RegExp(r'^([a-z]{0,4})\s*(\d+(?:\.\d+)?)?(?:\s+([a-z]))?$');

/// File names such as "1", "na", "na10", "ql11", "cm5.5", "cm c".
bool _isCodeName(String name) {
  final s = normalizeLoose(name);
  if (s.isEmpty) return true;
  final m = _codeName.firstMatch(s);
  return m != null && (m.group(1)!.isNotEmpty || m.group(2) != null);
}

/// Names that carry no title on their own, e.g. "Sword_CN".
bool _isMeaninglessName(String name) {
  if (_isCodeName(name)) return true;
  final s = normalizeLoose(name);
  return !containsCjk(s) && s.length <= 12 && !s.contains(' ') ||
      RegExp(r'^[a-z]+ cn$').hasMatch(s);
}

String _dirName(String dir) => dir.isEmpty ? '' : dir.split('/').last;

String _parentDir(String dir) {
  final i = dir.lastIndexOf('/');
  return i < 0 ? '' : dir.substring(0, i);
}

bool _isLongEnoughKey(String key) {
  if (key.isEmpty) return false;
  final cjk = containsCjk(key);
  return cjk ? key.runes.length >= 3 : key.length >= 5;
}

T? _mostCommon<T>(Iterable<T?> values) {
  final counts = <T, int>{};
  for (final v in values) {
    if (v == null) continue;
    counts[v] = (counts[v] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// Groups library entries into series and chapters.
///
/// The engine is deterministic and pure: the same input always gives the same
/// output, which is what lets manual corrections be stored on top of it.
RecognitionResult recognizeLibrary(
  List<LibraryEntry> entries, {
  Map<String, FolderRole> folderRoles = const {},
}) {
  final series = <RecognizedSeries>[];
  final suggestions = <MergeSuggestion>[];

  // ---- 0. Folders the user declared to be a series ----------------------
  final forced =
      folderRoles.entries
          .where((e) => e.value == FolderRole.series)
          .map((e) => e.key)
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length)); // innermost first
  if (forced.isNotEmpty) {
    final rest = <LibraryEntry>[];
    final byFolder = <String, List<LibraryEntry>>{};
    for (final e in entries) {
      final f = forced.where((d) => e.path.startsWith('$d/')).firstOrNull;
      if (f == null) {
        rest.add(e);
      } else {
        byFolder.putIfAbsent(f, () => []).add(e);
      }
    }
    for (final MapEntry(key: dir, value: list) in byFolder.entries) {
      final items = [for (final e in list) _Item(e, e.name, dir)];
      final built = _buildSeries(items, Confidence.high);
      final folderTitle = parseTitle(_dirName(dir));
      series.add(
        RecognizedSeries(
          id: 'folder:$dir',
          title: folderTitle.seriesTitle,
          author: folderTitle.authors.firstOrNull ?? built.author,
          circle: folderTitle.circle ?? built.circle,
          chapters: built.chapters,
          confidence: Confidence.high,
          folder: dir,
        ),
      );
    }
    entries = rest;
  }

  // ---- 1. Collapse wrapper folders -------------------------------------
  final byDir = <String, List<LibraryEntry>>{};
  for (final e in entries) {
    byDir.putIfAbsent(e.dir, () => []).add(e);
  }
  // Folders that contain entries deeper than their direct children.
  final dirsWithNested = <String>{};
  for (final e in entries) {
    var d = _parentDir(e.dir);
    while (true) {
      if (!dirsWithNested.add(d) || d.isEmpty) break;
      d = _parentDir(d);
    }
  }
  final items = <_Item>[];
  for (final e in entries) {
    final siblings = byDir[e.dir]!;
    final dir = e.dir;
    final isOnlyChild =
        dir.isNotEmpty && siblings.length == 1 && !dirsWithNested.contains(dir);
    if (isOnlyChild) {
      final folderName = _dirName(dir);
      final sameName = matchKey(folderName) == matchKey(e.name);
      final useFolderName =
          !sameName && _isMeaninglessName(e.name) && containsCjk(folderName);
      items.add(_Item(e, useFolderName ? folderName : e.name, _parentDir(dir)));
    } else {
      items.add(_Item(e, e.name, dir));
    }
  }

  // ---- 2. Series folders made of code-named files ----------------------
  final itemsByGroupDir = <String, List<_Item>>{};
  for (final it in items) {
    itemsByGroupDir.putIfAbsent(it.groupDir, () => []).add(it);
  }
  final consumed = <_Item>{};
  for (final entry in itemsByGroupDir.entries) {
    final dir = entry.key;
    final list = entry.value;
    if (dir.isEmpty || list.length < 2) continue;
    if (folderRoles[dir] == FolderRole.category) continue;
    final codes = list.where((i) => _isCodeName(i.name)).length;
    // At least two thirds code names: "1.pdf, 2.pdf, ql11.pdf".
    if (codes < 2 || codes * 3 < list.length * 2) continue;
    final folderTitle = parseTitle(_dirName(dir));
    final chapters = <RecognizedChapter>[];
    for (final it in list) {
      final m = _codeName.firstMatch(normalizeLoose(it.name));
      final numText = m?.group(2);
      final suffix = m?.group(3);
      double sortNumber;
      var uncertain = false;
      var kind = ChapterKind.normal;
      if (numText != null) {
        sortNumber = double.parse(numText);
      } else if (suffix != null || m == null) {
        // "cm c": cannot tell where it goes.
        sortNumber = double.infinity;
        uncertain = true;
        kind = ChapterKind.extra;
      } else {
        sortNumber = 1; // "na" next to "na2…na10" is chapter 1.
      }
      if (suffix != null && numText != null) uncertain = true;
      chapters.add(
        RecognizedChapter(
          entry: it.entry,
          parsed: it.parsed,
          sortNumber: sortNumber,
          kind: kind,
          uncertain: uncertain,
        ),
      );
      consumed.add(it);
    }
    _sortChapters(chapters);
    series.add(
      RecognizedSeries(
        id: 'folder:$dir',
        title: folderTitle.seriesTitle,
        author: folderTitle.authors.isEmpty ? null : folderTitle.authors.first,
        circle: folderTitle.circle,
        chapters: chapters,
        confidence: Confidence.high,
        folder: dir,
      ),
    );
  }

  // ---- 3. Group the rest by series key, split by creator --------------
  final byKey = <String, List<_Item>>{};
  final singles = <_Item>[];
  for (final it in items) {
    if (consumed.contains(it)) continue;
    final key = it.parsed.seriesKey;
    if (key.isEmpty) {
      singles.add(it);
    } else {
      byKey.putIfAbsent(key, () => []).add(it);
    }
  }

  final sortedKeys = byKey.keys.toList()..sort();
  for (final key in sortedKeys) {
    final group = byKey[key]!;
    if (group.length == 1) {
      singles.add(group.first);
      continue;
    }
    final clusters = _clusterByCreator(group);
    final built = <RecognizedSeries>[];
    for (final cluster in clusters) {
      if (_isHighConfidence(key, cluster)) {
        built.add(_buildSeries(cluster, Confidence.high));
      } else {
        for (final it in cluster) {
          built.add(_buildSeries([it], Confidence.medium));
        }
      }
    }
    series.addAll(built);
    if (built.length > 1) {
      suggestions.add(
        MergeSuggestion([
          for (final s in built) s.id,
        ], _describeSameTitle(clusters)),
      );
    }
  }
  for (final it in singles) {
    series.add(_buildSeries([it], Confidence.low));
  }

  // ---- 4. Similar titles by the same creator → suggestion -------------
  suggestions.addAll(_similarTitleSuggestions(series, suggestions));

  series.sort((a, b) => a.title.compareTo(b.title));
  return RecognitionResult(series, suggestions);
}

/// Items with overlapping creators end up in the same cluster. Items without
/// any creator join the cluster only when there is exactly one.
List<List<_Item>> _clusterByCreator(List<_Item> group) {
  final withCreator = group
      .where((i) => i.parsed.creatorKeys.isNotEmpty)
      .toList();
  final without = group.where((i) => i.parsed.creatorKeys.isEmpty).toList();
  final parent = List<int>.generate(withCreator.length, (i) => i);
  int find(int i) => parent[i] == i ? i : parent[i] = find(parent[i]);
  for (var i = 0; i < withCreator.length; i++) {
    for (var j = i + 1; j < withCreator.length; j++) {
      final a = withCreator[i].parsed;
      final b = withCreator[j].parsed;
      // Prefer author overlap (circle names have romanised aliases).
      final overlap = a.authorKeys.isNotEmpty && b.authorKeys.isNotEmpty
          ? a.authorKeys.intersection(b.authorKeys).isNotEmpty
          : a.creatorKeys.intersection(b.creatorKeys).isNotEmpty;
      if (overlap) parent[find(i)] = find(j);
    }
  }
  final clusters = <int, List<_Item>>{};
  for (var i = 0; i < withCreator.length; i++) {
    clusters.putIfAbsent(find(i), () => []).add(withCreator[i]);
  }
  final result = clusters.values.toList();
  if (without.isNotEmpty) {
    if (result.length == 1) {
      result.first.addAll(without);
    } else {
      result.add(without);
    }
  }
  return result;
}

bool _isHighConfidence(String key, List<_Item> cluster) {
  if (cluster.length < 2) return true;
  final numbered = cluster.where(
    (i) =>
        i.parsed.chapter.hasNumber ||
        i.parsed.chapter.kind != ChapterKind.normal,
  );
  // Same title without any numbering: duplicates or different works.
  if (numbered.isEmpty) return false;
  // Two unnumbered plain items cannot both be chapter 1.
  final plain = cluster.where(
    (i) =>
        !i.parsed.chapter.hasNumber &&
        i.parsed.chapter.kind == ChapterKind.normal,
  );
  if (plain.length > 1) return false;
  if (_isLongEnoughKey(key)) return true;
  // Short keys only when everything sits in one folder.
  return cluster.map((i) => i.groupDir).toSet().length == 1;
}

String _describeSameTitle(List<List<_Item>> clusters) {
  final creators = clusters
      .map((c) => _mostCommon(c.expand((i) => i.parsed.authors)))
      .whereType<String>()
      .toSet();
  if (creators.length > 1) return '标题相同，但作者不同（${creators.join(' / ')}）';
  return '标题相同，但缺少章节编号';
}

RecognizedSeries _buildSeries(List<_Item> cluster, Confidence confidence) {
  final chapters = <RecognizedChapter>[];
  final hasNumbered = cluster.any((i) => i.parsed.chapter.hasNumber);
  for (final it in cluster) {
    final ch = it.parsed.chapter;
    double sortNumber;
    if (ch.hasNumber) {
      sortNumber = ch.number!;
    } else if (ch.kind == ChapterKind.normal) {
      // "他人になるクスリ" next to "…2", "…3" is the first chapter.
      sortNumber = hasNumbered ? 1 : 0;
    } else {
      sortNumber = double.infinity;
    }
    chapters.add(
      RecognizedChapter(
        entry: it.entry,
        parsed: it.parsed,
        sortNumber: sortNumber,
        kind: ch.kind,
      ),
    );
  }
  _sortChapters(chapters);
  final first = cluster.first;
  final title = cluster.length == 1
      ? first.parsed.seriesTitle
      : _mostCommon(cluster.map((i) => i.parsed.seriesTitle))!;
  final id = cluster.length == 1
      ? 'item:${first.entry.path}'
      : 'title:${first.parsed.seriesKey}|${_creatorId(cluster)}';
  return RecognizedSeries(
    id: id,
    title: title,
    author: _mostCommon(cluster.expand((i) => i.parsed.authors)),
    circle: _mostCommon(cluster.map((i) => i.parsed.circle)),
    chapters: chapters,
    confidence: confidence,
  );
}

String _creatorId(List<_Item> cluster) {
  final keys = cluster.expand((i) => i.parsed.authorKeys).toList()..sort();
  return keys.isEmpty ? '' : keys.first;
}

void _sortChapters(List<RecognizedChapter> chapters) {
  chapters.sort((a, b) {
    final k = a.kind.index.compareTo(b.kind.index);
    if (k != 0) return k;
    final n = a.sortNumber.compareTo(b.sortNumber);
    if (n != 0) return n;
    // Variant notes ("好分支") come after the plain chapter.
    final la = a.parsed.chapter.label == null ? 0 : 1;
    final lb = b.parsed.chapter.label == null ? 0 : 1;
    if (la != lb) return la.compareTo(lb);
    return a.entry.path.compareTo(b.entry.path);
  });
}

// ---------------------------------------------------------------------------
// Similar-title suggestions

List<MergeSuggestion> _similarTitleSuggestions(
  List<RecognizedSeries> series,
  List<MergeSuggestion> existing,
) {
  final already = <String>{
    for (final s in existing)
      for (final a in s.seriesIds)
        for (final b in s.seriesIds)
          if (a.compareTo(b) < 0) '$a\n$b',
  };
  // Index series by creator key; compare only within the same creator.
  final byCreator = <String, List<RecognizedSeries>>{};
  final keys = <RecognizedSeries, String>{};
  for (final s in series) {
    if (s.folder != null) continue;
    keys[s] = matchKey(s.title);
    final creators = <String>{
      for (final c in s.chapters) ...c.parsed.authorKeys,
    };
    for (final c in creators) {
      byCreator.putIfAbsent(c, () => []).add(s);
    }
  }
  final result = <MergeSuggestion>[];
  final seen = <String>{};
  for (final list in byCreator.values) {
    if (list.length < 2 || list.length > 400) continue;
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        final a = list[i];
        final b = list[j];
        final ids = [a.id, b.id]..sort();
        final pair = ids.join('\n');
        if (seen.contains(pair) || already.contains(pair)) continue;
        final ka = keys[a]!;
        final kb = keys[b]!;
        if (ka == kb) continue;
        final reason = _similarReason(ka, kb);
        if (reason != null) {
          seen.add(pair);
          result.add(MergeSuggestion(ids, '同一作者，$reason'));
        }
      }
    }
  }
  return result;
}

String? _similarReason(String a, String b) {
  final shorter = a.length <= b.length ? a : b;
  final longer = a.length <= b.length ? b : a;
  if (shorter.runes.length < 4) return null;
  final sim = _similarity(a, b);
  if (sim >= 0.8) return '标题高度相似';
  if (longer.startsWith(shorter) && shorter.runes.length >= 5) {
    return '标题开头相同';
  }
  return null;
}

/// 1 - normalised Levenshtein distance.
double _similarity(String a, String b) {
  final x = a.runes.toList();
  final y = b.runes.toList();
  if (x.isEmpty || y.isEmpty) return 0;
  var prev = List<int>.generate(y.length + 1, (i) => i);
  for (var i = 1; i <= x.length; i++) {
    final cur = List<int>.filled(y.length + 1, 0)..[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final cost = x[i - 1] == y[j - 1] ? 0 : 1;
      cur[j] = math.min(
        math.min(cur[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    prev = cur;
  }
  return 1 - prev[y.length] / math.max(x.length, y.length);
}
