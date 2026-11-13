/// Text helpers shared by the recognition engine.
library;

/// Converts full-width ASCII (Ｆ, １, （) to half-width and unifies a few
/// look-alike characters so that matching is not fooled by typography.
String toHalfWidth(String input) {
  final buf = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      // Keep the full-width tilde: it is used as a subtitle delimiter (～).
      if (rune == 0xFF5E) {
        buf.writeCharCode(rune);
      } else {
        buf.writeCharCode(rune - 0xFEE0);
      }
    } else if (rune == 0x3000) {
      buf.writeCharCode(0x20);
    } else {
      buf.writeCharCode(rune);
    }
  }
  return buf.toString();
}

/// Normalisation used for display-independent comparisons:
/// half-width, lower case, underscores as spaces, collapsed whitespace.
String normalizeLoose(String input) {
  var s = toHalfWidth(input).toLowerCase();
  s = s.replaceAll('_', ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

/// A compact key used to decide whether two titles are "the same title".
/// Removes whitespace and punctuation, keeps letters/digits/CJK/kana.
String matchKey(String input) {
  final s = normalizeLoose(input);
  final buf = StringBuffer();
  for (final rune in s.runes) {
    if (_isWordRune(rune)) buf.writeCharCode(rune);
  }
  return _foldVariants(buf.toString());
}

bool _isWordRune(int r) {
  if (r >= 0x30 && r <= 0x39) return true; // 0-9
  if (r >= 0x61 && r <= 0x7A) return true; // a-z
  if (r >= 0xC0 && r <= 0x24F) return true; // latin accents
  if (r >= 0x3040 && r <= 0x30FF && r != 0x30FB) return true; // kana (minus ・)
  if (r == 0x30FC) return true; // ー
  if (r >= 0x3400 && r <= 0x9FFF) return true; // CJK
  if (r >= 0xF900 && r <= 0xFAFF) return true; // CJK compat
  if (r >= 0xAC00 && r <= 0xD7AF) return true; // hangul
  if (r == 0x3005) return true; // 々
  return false;
}

/// Folds a few traditional/simplified and Japanese/Chinese variants that are
/// common in comic file names, so "媽媽" and "妈妈" compare equal.
String _foldVariants(String s) {
  if (s.isEmpty) return s;
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    buf.write(_variantMap[ch] ?? ch);
  }
  return buf.toString();
}

const Map<String, String> _variantMap = {
  '媽': '妈',
  '與': '与',
  '裝': '装',
  '話': '话',
  '說': '说',
  '亂': '乱',
  '換': '换',
  '體': '体',
  '對': '对',
  '這': '这',
  '們': '们',
  '個': '个',
  '開': '开',
  '關': '关',
  '時': '时',
  '後': '后',
  '來': '来',
  '會': '会',
  '為': '为',
  '的': '的',
  '戀': '恋',
  '戦': '战',
  '戰': '战',
  '學': '学',
  '処': '处',
  '處': '处',
  '譯': '译',
  '訳': '译',
  '編': '编',
  '篇': '篇',
  '総': '总',
  '總': '总',
  '集': '集',
  '着': '着',
  '著': '着',
  '獵': '猎',
  '騎': '骑',
  '鐵': '铁',
  '鉄': '铁',
  '轉': '转',
  '転': '转',
  '靈': '灵',
  '霊': '灵',
  '魂': '魂',
  '憑': '凭',
  '異': '异',
  '贊': '赞',
  '彼': '彼',
};

bool containsCjk(String s) {
  for (final r in s.runes) {
    if ((r >= 0x3040 && r <= 0x30FF) ||
        (r >= 0x3400 && r <= 0x9FFF) ||
        (r >= 0xAC00 && r <= 0xD7AF)) {
      return true;
    }
  }
  return false;
}

/// Parses Chinese numerals such as 一, 十二, 二十, 廿一, 百. Returns null if the
/// text is not a Chinese numeral.
int? parseChineseNumber(String s) {
  if (s.isEmpty) return null;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (s == '廿') return 20;
  if (s.startsWith('廿')) {
    final rest = parseChineseNumber(s.substring(1));
    return rest == null ? null : 20 + rest;
  }
  var total = 0;
  var current = 0;
  var any = false;
  for (final ch in s.split('')) {
    if (digits.containsKey(ch)) {
      current = digits[ch]!;
      any = true;
    } else if (ch == '十') {
      total += (current == 0 ? 1 : current) * 10;
      current = 0;
      any = true;
    } else if (ch == '百') {
      total += (current == 0 ? 1 : current) * 100;
      current = 0;
      any = true;
    } else {
      return null;
    }
  }
  return any ? total + current : null;
}

/// Parses Roman numerals, both ASCII (IV) and the Unicode forms (Ⅳ).
int? parseRomanNumber(String s) {
  const unicode = {
    'Ⅰ': 1,
    'Ⅱ': 2,
    'Ⅲ': 3,
    'Ⅳ': 4,
    'Ⅴ': 5,
    'Ⅵ': 6,
    'Ⅶ': 7,
    'Ⅷ': 8,
    'Ⅸ': 9,
    'Ⅹ': 10,
    'Ⅺ': 11,
    'Ⅻ': 12,
    'ⅰ': 1,
    'ⅱ': 2,
    'ⅲ': 3,
    'ⅳ': 4,
    'ⅴ': 5,
    'ⅵ': 6,
    'ⅶ': 7,
    'ⅷ': 8,
    'ⅸ': 9,
    'ⅹ': 10,
  };
  if (s.length == 1 && unicode.containsKey(s)) return unicode[s];
  final up = s.toUpperCase();
  if (!RegExp(r'^[IVX]{1,5}$').hasMatch(up)) return null;
  const v = {'I': 1, 'V': 5, 'X': 10};
  var total = 0;
  for (var i = 0; i < up.length; i++) {
    final cur = v[up[i]]!;
    final next = i + 1 < up.length ? v[up[i + 1]]! : 0;
    total += cur < next ? -cur : cur;
  }
  return total;
}
