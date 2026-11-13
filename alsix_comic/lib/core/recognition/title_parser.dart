import 'text_utils.dart';

/// What kind of chapter an item is. The order of the values is the order in
/// which they are listed inside a series.
enum ChapterKind {
  /// Regular numbered (or implicitly numbered) chapter.
  normal,

  /// Named side chapter: 美遊編, 番外, Side story, 後日談, DLC…
  extra,

  /// 総集編 / 总集篇 / 合集: always listed last.
  compilation,
}

class ChapterInfo {
  const ChapterInfo({
    this.number,
    this.numberEnd,
    this.kind = ChapterKind.normal,
    this.label,
    this.subtitle,
  });

  /// Chapter number, e.g. 2, 2.5, 1.0. Null when the name carries none.
  final double? number;

  /// End of a range ("第1-4話" → number 1, numberEnd 4).
  final double? numberEnd;
  final ChapterKind kind;

  /// Short variant note attached to the number: "好分支", "手繪".
  final String? label;

  /// Subtitle such as "玉藻の前" or "美遊編".
  final String? subtitle;

  bool get hasNumber => number != null;

  @override
  String toString() =>
      'Ch(${number ?? '-'}${numberEnd != null ? '~$numberEnd' : ''} '
      '${kind.name}${label != null ? ' [$label]' : ''}'
      '${subtitle != null ? ' «$subtitle»' : ''})';
}

/// Result of parsing one file or folder name.
class ParsedTitle {
  ParsedTitle({
    required this.raw,
    required this.title,
    required this.seriesTitle,
    required this.seriesKey,
    required this.chapter,
    this.circle,
    this.authors = const [],
    this.event,
    this.source,
    this.notes = const [],
  });

  /// Original name (file name without extension, or folder name).
  final String raw;

  /// Clean display title: noise removed, number and subtitle kept.
  final String title;

  /// Title of the series this item belongs to (no number, no subtitle).
  final String seriesTitle;

  /// [matchKey] of [seriesTitle]; empty when nothing meaningful is left.
  final String seriesKey;
  final ChapterInfo chapter;
  final String? circle;
  final List<String> authors;
  final String? event;

  /// Original work being parodied, e.g. "FateGrand Order".
  final String? source;

  /// Everything stripped as noise (translator group, [DL版], magazine…).
  final List<String> notes;

  /// Returns a copy that takes [authors] when this title names none.
  ParsedTitle inheritAuthors(List<String> inherited) {
    if (authors.isNotEmpty || circle != null || inherited.isEmpty) return this;
    return ParsedTitle(
      raw: raw,
      title: title,
      seriesTitle: seriesTitle,
      seriesKey: seriesKey,
      chapter: chapter,
      authors: inherited,
      event: event,
      source: source,
      notes: notes,
    );
  }

  /// Keys identifying the creator: authors and circle.
  Set<String> get creatorKeys => {
    for (final a in authors) matchKey(a),
    if (circle != null) matchKey(circle!),
  }..remove('');

  Set<String> get authorKeys =>
      {for (final a in authors) matchKey(a)}..remove('');

  @override
  String toString() =>
      'ParsedTitle(series: "$seriesTitle", $chapter, authors: $authors, '
      'circle: $circle)';
}

// ---------------------------------------------------------------------------

final _noiseWords = RegExp(
  r'中国翻訳|中国語|中國翻譯|中國語|中文|chinese|汉化|漢化|翻译|翻譯|翻訳|渣翻|机翻|'
  r'dl版|digital|無修正|无修正|decensored|uncensored|ページ欠落|english|英訳|'
  r'ai[ _]?generated|個人|个人|重嵌|全彩|colou?rized|e-hentai|扫图|掃圖|嵌字|'
  r'^\d+\s*p$|^\d+\s*pages?$',
  caseSensitive: false,
);

final _magazineWords = RegExp(
  r'comic|コミック|vol\.?\s*\d|月号|\d{4}\s*[-年]\s*\d{1,2}|アンソロジー|anthology|'
  r'の本|のほん|magnum|unreal|アンリアル',
  caseSensitive: false,
);

final _eventPattern = RegExp(
  r'^(c\d{2,3}|comic1|#|例大祭|コミティア|サンクリ|紅楼夢|cotton|ふたけっと|'
  r'こみトレ|サンシャイン|僕らのラブライブ|歌姫庭園|scramble|ショタスクラッチ)|\d',
  caseSensitive: false,
);

/// Words that sometimes trail a title outside of brackets.
final _trailingNoise = RegExp(
  r'(\s+(中文|chinese|cn|中国翻訳|dl版|digital))+$',
  caseSensitive: false,
);

final _eHentaiSuffix = RegExp(
  r'\s*-\s*E-Hentai Galleries\.?\d*\s*$',
  caseSensitive: false,
);
final _leadingDate = RegExp(r'^\d{2,4}[-.]\d{1,2}[-.]\d{1,2}\s*');

const _closing = {'[': ']', '(': ')', '【': '】', '「': '」', '『': '』'};

class _Group {
  _Group(this.open, this.content, this.start, this.end);
  final String open;
  final String content;
  final int start;
  final int end;
}

/// Finds the matching close bracket, honouring nesting of the same type.
int _findClose(String s, int openIdx) {
  final open = s[openIdx];
  final close = _closing[open]!;
  var depth = 0;
  for (var i = openIdx; i < s.length; i++) {
    if (s[i] == open) depth++;
    if (s[i] == close) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

bool isNoise(String content) => _noiseWords.hasMatch(content.trim());

List<String> _splitPeople(String s) => s
    .split(RegExp(r'\s*[,、&×]\s*'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

/// Parses a single file/folder name. [name] must not contain the extension.
ParsedTitle parseTitle(String name) {
  final raw = name;
  var s = toHalfWidth(name).replaceAll('_', ' ');
  s = s.replaceAll(_eHentaiSuffix, '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  final notes = <String>[];
  String? circle;
  final authors = <String>[];
  String? event;
  String? source;
  String? label;
  double? parenNumber;
  double? partHint;

  final dateMatch = _leadingDate.firstMatch(s);
  if (dateMatch != null) {
    notes.add(dateMatch.group(0)!.trim());
    s = s.substring(dateMatch.end);
  }

  // Broken leading author such as "(DATE)] 他人になるクスリ5".
  final broken = RegExp(r'^\(([^()\[\]]+)\)\]\s*').firstMatch(s);
  if (broken != null) {
    authors.addAll(_splitPeople(broken.group(1)!));
    s = s.substring(broken.end);
  }

  // ---- Leading bracket groups: event, circle/author --------------------
  String? lastLeadingContent;
  while (s.isNotEmpty && (s[0] == '[' || s[0] == '(' || s[0] == '【')) {
    final close = _findClose(s, 0);
    if (close < 0) break;
    final content = s.substring(1, close).trim();
    final open = s[0];
    s = s.substring(close + 1).trimLeft();
    if (s.startsWith(']')) s = s.substring(1).trimLeft();
    lastLeadingContent = content;
    if (content.isEmpty) continue;
    if (isNoise(content)) {
      notes.add(content);
      continue;
    }
    if (open == '(') {
      if (_eventPattern.hasMatch(content) && event == null) {
        event = content;
      } else {
        authors.addAll(_splitPeople(content));
      }
    } else {
      // [Circle (Author)] or [Author]
      final m = RegExp(r'^(.*?)\s*\((.+)\)\s*$').firstMatch(content);
      if (m != null && m.group(1)!.isNotEmpty) {
        circle ??= m.group(1)!.trim();
        authors.addAll(_splitPeople(m.group(2)!));
      } else if (authors.isEmpty && circle == null) {
        authors.addAll(_splitPeople(content));
      } else {
        notes.add(content);
      }
    }
  }
  if (s.trim().isEmpty && lastLeadingContent != null) {
    // Whole name was a bracket, e.g. "【推しの皮】".
    s = lastLeadingContent;
    authors.clear();
  }

  // ---- Remaining bracket groups anywhere in the title -----------------
  final groups = <_Group>[];
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (_closing.containsKey(ch) && ch != '「' && ch != '『') {
      final close = _findClose(s, i);
      if (close < 0) continue;
      groups.add(_Group(ch, s.substring(i + 1, close).trim(), i, close));
      i = close;
    }
  }
  final body = StringBuffer();
  var cursor = 0;
  for (final g in groups) {
    body.write(s.substring(cursor, g.start));
    body.write(' ');
    cursor = g.end + 1;
    final c = g.content;
    if (c.isEmpty) continue;
    if (_partOrder.containsKey(c)) {
      partHint ??= _partOrder[c];
      continue;
    }
    if (g.open == '(') {
      if (RegExp(r'^\d+(\.\d+)?$').hasMatch(c)) {
        parenNumber ??= double.parse(c);
      } else if (isNoise(c) || _magazineWords.hasMatch(c)) {
        notes.add(c);
      } else if (c.runes.length <= 6 &&
          containsCjk(c) &&
          g.start > 0 &&
          RegExp(r'\d$').hasMatch(s.substring(0, g.start).trimRight())) {
        label ??= c;
      } else {
        source ??= c;
        if (source != c) notes.add(c);
      }
    } else {
      notes.add(c);
    }
  }
  body.write(s.substring(cursor));
  var text = body.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text.replaceAll(_trailingNoise, '').trim();
  if (text.isEmpty) text = s.trim();

  final displayTitle = text;
  final chapter = _extractChapter(
    text,
    label: label,
    parenNumber: parenNumber ?? partHint,
  );

  var seriesTitle = chapter.$1.trim().replaceAll(
    RegExp(r'\s+(ch|vol|ep|chapter|no)\.?$', caseSensitive: false),
    '',
  );
  seriesTitle = seriesTitle
      .replaceAll(RegExp(r'[\s\-–—:：!！?？.。,、~～+]+$'), '')
      .trim();
  if (seriesTitle.isEmpty) seriesTitle = displayTitle;

  return ParsedTitle(
    raw: raw,
    title: displayTitle,
    seriesTitle: seriesTitle,
    seriesKey: matchKey(seriesTitle),
    chapter: chapter.$2,
    circle: circle,
    authors: authors,
    event: event,
    source: source,
    notes: notes,
  );
}

// ---------------------------------------------------------------------------
// Chapter extraction

/// Parts sort as 1 < 1.5 < 2 so that "上/下" followed by "03" stays in order.
const _partOrder = {
  '上': 1.0,
  '中': 1.5,
  '下': 2.0,
  '上巻': 1.0,
  '下巻': 2.0,
  '前編': 1.0,
  '前篇': 1.0,
  '中編': 1.5,
  '中篇': 1.5,
  '後編': 2.0,
  '後篇': 2.0,
  '后篇': 2.0,
};

const _cnDigits = '零〇一二两兩三四五六七八九十百廿';
final _chapterUnit = '話话回章巻卷篇部集';

final _compilationMarker = RegExp(
  r'総集編|總集篇|总集篇|総集篇|总集编|合集|complete edition',
  caseSensitive: false,
);
final _extraMarker = RegExp(
  r'番外(?:編|篇|编)?|外伝|外传|前傳|前传|前日譚|前日谭|prequel|後日談|后日谈|后日談|後日谈|side\s*story|\bside\b|dlc\b|おまけ',
  caseSensitive: false,
);

(String, ChapterInfo) _extractChapter(
  String text, {
  String? label,
  double? parenNumber,
}) {
  var s = text;
  double? number;
  double? numberEnd;
  var kind = ChapterKind.normal;
  String? subtitle;

  // 1. Explicit markers anywhere: 第1-4話, 第11話, 第一话, 1巻, 1枚目.
  final range = RegExp(
    '第\\s*(\\d+(?:\\.\\d+)?)\\s*[-~～]\\s*(\\d+(?:\\.\\d+)?)\\s*[$_chapterUnit]?',
  ).firstMatch(s);
  if (range != null) {
    number = double.parse(range.group(1)!);
    numberEnd = double.parse(range.group(2)!);
    s = s.replaceRange(range.start, range.end, ' ');
  } else {
    final explicit = RegExp(
      '第\\s*(\\d+(?:\\.\\d+)?|[$_cnDigits]+)\\s*[$_chapterUnit]',
    ).firstMatch(s);
    if (explicit != null) {
      final g = explicit.group(1)!;
      number = double.tryParse(g) ?? parseChineseNumber(g)?.toDouble();
      s = s.replaceRange(explicit.start, explicit.end, ' ');
    } else {
      final unit = RegExp('(\\d+(?:\\.\\d+)?)\\s*(?:巻|卷|話|话|枚目|回目)')
          .firstMatch(s);
      if (unit != null) {
        number = double.parse(unit.group(1)!);
        s = s.replaceRange(unit.start, unit.end, ' ');
      }
    }
  }

  // 2. Compilation / extra markers.
  final comp = _compilationMarker.firstMatch(s);
  final extra = comp == null ? _extraMarker.firstMatch(s) : null;
  final marker = comp ?? extra;
  if (marker != null &&
      extra != null &&
      RegExp(r'\+\s*$').hasMatch(s.substring(0, marker.start))) {
    // "師弟的復仇 1-3+番外", "黒之受肉+后日谈": main story bundled with an
    // extra. It is a normal chapter; keep the note as a label.
    label ??= s.substring(marker.start, marker.end).trim();
    s =
        s.substring(0, marker.start).replaceAll(RegExp(r'\+\s*$'), '') +
        s.substring(marker.end);
  } else if (marker != null) {
    kind = comp != null ? ChapterKind.compilation : ChapterKind.extra;
    final before = s.substring(0, marker.start).trim();
    final after = s.substring(marker.end).trim();
    subtitle = s.substring(marker.start, marker.end).trim();
    if (after.isNotEmpty) subtitle = '$subtitle $after';
    s = before.isNotEmpty ? before : after;
  }

  // Number written after a closed subtitle: "…～中でイったら交換してね～ 1".
  if (number == null) {
    final afterSub = RegExp(r'[～~」』]\s*(\d+(?:\.\d+)?)$').firstMatch(s);
    if (afterSub != null) {
      number = double.parse(afterSub.group(1)!);
      s = s.substring(0, afterSub.start + 1);
    }
  }

  // 3. Subtitle split: ～…～, ~…~, 「…」, 『…』, " -…-", " - …", "2.0-xxx-".
  final dashSub = RegExp(r'^(.*\S)-([^-]+)-$').firstMatch(s);
  if (dashSub != null) {
    subtitle = subtitle ?? dashSub.group(2)!.trim();
    s = dashSub.group(1)!;
  }
  final sub = RegExp(r'\s*(?:[～~「『]|\s-\s?(?=\S)|\s–\s)').firstMatch(s);
  if (sub != null && sub.start > 0) {
    final rest = s
        .substring(sub.start)
        .replaceAll(RegExp(r'^[\s～~「『\-–]+|[\s～~」』\-–]+$'), '')
        .trim();
    final head = s.substring(0, sub.start).trim();
    if (head.isNotEmpty) {
      if (rest.isNotEmpty) {
        subtitle = subtitle == null ? rest : '$rest $subtitle';
      }
      s = head;
    }
  }

  if (number != null) {
    // "…日常EX1 第一话": drop a trailing duplicate of the explicit number.
    final dup = RegExp(
      r'(?:(?<![a-z])ex)?\s*(\d+(?:\.\d+)?)$',
      caseSensitive: false,
    ).firstMatch(s.trimRight());
    if (dup != null && double.parse(dup.group(1)!) == number && dup.start > 0) {
      s = s.trimRight().substring(0, dup.start);
    }
  }

  if (number == null) {
    // 4. Range at the end: "染指 1-4", "妈妈1-2".
    final endRange = RegExp(r'^(.*?\D)\s*(\d+)\s*-\s*(\d+)$').firstMatch(s);
    if (endRange != null) {
      number = double.parse(endRange.group(2)!);
      numberEnd = double.parse(endRange.group(3)!);
      s = endRange.group(1)!;
    }
  }

  if (number == null) {
    // 5. vol / ch / # / EX prefixes at the end.
    final pref = RegExp(
      r'^(.*?)(?:(?:^|\s)(?:vol|ch|chapter|ep|no)\.?|#|(?<![a-z])ex\.?)\s*(\d+(?:\.\d+)?)$',
      caseSensitive: false,
    ).firstMatch(s);
    if (pref != null && pref.group(1)!.trim().isNotEmpty) {
      number = double.parse(pref.group(2)!);
      s = pref.group(1)!;
    }
  }

  if (number == null) {
    // 6. Trailing number, optionally followed by "+5.2": "クスリ5 +5.2".
    final trail = RegExp(
      r'^(.*?[^\d\s.])\s*(\d+(?:\.\d+)?)(?:\s*\+\s*\d+(?:\.\d+)?)?$',
    ).firstMatch(s);
    if (trail != null) {
      number = double.parse(trail.group(2)!);
      s = trail.group(1)!;
    }
  }

  if (number == null) {
    // 7. Number glued to the title, then a space and a subtitle:
    //    "とろ娘13 チノちゃん…", "移魂水晶3 魂転水晶".
    final mid = RegExp(r'^(.*?[^\d\s.\-])(\d+(?:\.\d+)?)\s+(\S.*)$')
        .firstMatch(s);
    if (mid != null && !RegExp(r'^\d').hasMatch(mid.group(3)!)) {
      number = double.parse(mid.group(2)!);
      subtitle ??= mid.group(3)!.trim();
      s = mid.group(1)!;
    }
  }

  if (number == null) {
    // 8. Parts: 上/中/下, 前編/後編.
    final part = RegExp(r'^(.*?)[\s\-]*(前編|中編|後編|前篇|中篇|後篇|后篇|上|中|下)$')
        .firstMatch(s);
    if (part != null &&
        part.group(1)!.trim().isNotEmpty &&
        (part.group(2)!.length > 1 ||
            RegExp(r'[\s\-]$').hasMatch(s.substring(0, s.length - 1)))) {
      number = _partOrder[part.group(2)!];
      s = part.group(1)!;
    }
  }

  if (number == null) {
    // 9. Roman numerals at the end: "Ⅱ", " II".
    final roman =
        RegExp(r'^(.*?)\s*([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ])$').firstMatch(s) ??
        RegExp(r'^(.*\S)\s+([IVX]{1,4})$').firstMatch(s) ??
        RegExp(r'^(.*[^\x00-\x7F])(IX|IV|VI{0,3}|I{2,3})$').firstMatch(s);
    if (roman != null) {
      number = parseRomanNumber(roman.group(2)!)?.toDouble();
      s = roman.group(1)!;
    }
  }

  number ??= parenNumber;

  // A named arc without a number ("～美遊編～") is a side chapter.
  if (number == null &&
      kind == ChapterKind.normal &&
      subtitle != null &&
      RegExp(r'[編篇编]$').hasMatch(subtitle)) {
    kind = ChapterKind.extra;
  }

  return (
    s,
    ChapterInfo(
      number: number,
      numberEnd: numberEnd,
      kind: kind,
      label: label,
      subtitle: subtitle,
    ),
  );
}
