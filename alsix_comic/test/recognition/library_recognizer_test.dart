import 'package:alsix_comic/core/recognition/library_recognizer.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixture.dart';

List<LibraryEntry> entries(List<String> paths) => [
  for (final p in paths)
    LibraryEntry(p, p.endsWith('.pdf') ? EntryType.pdf : EntryType.imageFolder),
];

RecognizedSeries seriesWith(RecognitionResult r, String pathPart) =>
    r.series.firstWhere(
      (s) => s.chapters.any((c) => c.entry.path.contains(pathPart)),
      orElse: () => throw StateError('no series contains "$pathPart"'),
    );

List<String> chapterFiles(RecognizedSeries s) => [
  for (final c in s.chapters) c.entry.path.split('/').last,
];

void main() {
  group('folder roles', () {
    test('code-named files take the folder name as series', () {
      final r = recognizeLibrary(
        entries([
          'kaba/怪异情侣/1.pdf',
          'kaba/怪异情侣/10.pdf',
          'kaba/怪异情侣/2.pdf',
          'kaba/怪异情侣/ql11.pdf',
          'kaba/怪异情侣/ql12.pdf',
        ]),
      );
      final s = seriesWith(r, '怪异情侣');
      expect(s.title, '怪异情侣');
      expect(chapterFiles(s), [
        '1.pdf',
        '2.pdf',
        '10.pdf',
        'ql11.pdf',
        'ql12.pdf',
      ]);
    });

    test('unnumbered code is chapter 1, odd suffix is uncertain', () {
      final r = recognizeLibrary(
        entries([
          'kaba/溺爱/na.pdf',
          'kaba/溺爱/na2.pdf',
          'kaba/溺爱/na10.pdf',
          'kaba/痴迷/cm.pdf',
          'kaba/痴迷/cm2.pdf',
          'kaba/痴迷/cm5.5.pdf',
          'kaba/痴迷/cm5.pdf',
          'kaba/痴迷/cm c.pdf',
        ]),
      );
      expect(chapterFiles(seriesWith(r, '溺爱')), [
        'na.pdf',
        'na2.pdf',
        'na10.pdf',
      ]);
      final cm = seriesWith(r, '痴迷');
      expect(chapterFiles(cm), [
        'cm.pdf',
        'cm2.pdf',
        'cm5.pdf',
        'cm5.5.pdf',
        'cm c.pdf',
      ]);
      expect(cm.chapters.last.uncertain, isTrue);
      expect(cm.hasUncertainChapter, isTrue);
    });

    test('category folders do not become series', () {
      final r = recognizeLibrary(
        entries([
          'A级/(谷口さん)コウカン [中国翻訳] [DL版].pdf',
          'A级/[DATE] 同居する粘液 [中国翻訳] [DL版] [洨五組].pdf',
          'A级/The pervert is me.pdf',
        ]),
      );
      expect(r.series, hasLength(3));
      expect(r.series.every((s) => s.title != 'A级'), isTrue);
    });

    test('wrapper folders are collapsed', () {
      final r = recognizeLibrary(
        entries([
          '皮物/伊人酒吧/伊人酒吧1/伊人酒吧1.pdf',
          '皮物/伊人酒吧/伊人酒吧2/伊人酒吧2.pdf',
          '皮物/伊人酒吧/伊人酒吧3/伊人酒吧3.pdf',
        ]),
      );
      final s = seriesWith(r, '伊人酒吧1');
      expect(s.title, '伊人酒吧');
      expect(s.chapters, hasLength(3));
      expect(s.confidence, Confidence.high);
    });

    test('meaningless file name in its own folder uses the folder name', () {
      final r = recognizeLibrary(entries(['换身/绝区零/Sword_CN.pdf']));
      expect(r.series.single.title, '绝区零');
    });
  });

  group('series merging', () {
    test('parts and numbers in order', () {
      final r = recognizeLibrary(
        entries([
          '合集/媽媽的味道03.pdf',
          '合集/媽媽的味道-下.pdf',
          '合集/媽媽的味道-上.pdf',
          '合集/媽媽的味道04.pdf',
        ]),
      );
      expect(chapterFiles(seriesWith(r, '媽媽的味道03')), [
        '媽媽的味道-上.pdf',
        '媽媽的味道-下.pdf',
        '媽媽的味道03.pdf',
        '媽媽的味道04.pdf',
      ]);
    });

    test('versions, named arcs and compilation', () {
      final r = recognizeLibrary(
        entries([
          'A+/(谷口さん)君になる～美遊編～ (Fatekaleid liner プリズマ☆イリヤ) [中国翻訳].pdf',
          'A+/(谷口さん)君になる3.0～カーマ～ (FateGrand Order) [中国翻訳].pdf',
          'A+/(谷口さん)君になる1.0(FateGrand Order) [中国翻訳] [DL版].pdf',
          'A+/(谷口さん)君になる総集編 ゲスト様(FateGrand Order) [中国翻訳] [DL版].pdf',
          'A+/(谷口さん)君になる2.1～ジャンヌ・オルタ～ (FateGrand Order) [中国翻訳] [DL版].pdf',
          'A+/(谷口さん)君になる1.5 -玉藻の前-(FateGrand Order) [中国翻訳].pdf',
        ]),
      );
      final s = seriesWith(r, '君になる1.0');
      expect(s.confidence, Confidence.high);
      expect(s.chapters.map((c) => c.sortNumber).take(4), [1.0, 1.5, 2.1, 3.0]);
      expect(s.chapters[4].entry.path, contains('美遊編'));
      expect(s.chapters[5].entry.path, contains('総集編'));
    });

    test('branch comes after the plain chapter', () {
      final r = recognizeLibrary(
        entries([
          '皮物/邻家的天使大人/邻家的天使大人4（好分支）.pdf',
          '皮物/邻家的天使大人/邻家的天使大人4.pdf',
          '皮物/邻家的天使大人/邻家的天使大人1.pdf',
        ]),
      );
      expect(chapterFiles(seriesWith(r, '邻家的天使大人1')), [
        '邻家的天使大人1.pdf',
        '邻家的天使大人4.pdf',
        '邻家的天使大人4（好分支）.pdf',
      ]);
    });

    test('circle aliases and missing authors merge across folders', () {
      final r = recognizeLibrary(
        entries([
          'A+/[Senpenbankashiki (DATE)] 他人になるクスリ4 [Chinese] [熊崎玉子汉化组].pdf',
          'A+/[千変万化式 (DATE)] 他人になるクスリ [中国翻訳] [DL版] [无毒汉化组].pdf',
          'A+/他人になるクスリ8.pdf',
          '已审核/附身/[千変万化式 (DATE)] 他人になるクスリ7 + 7.2 [中国翻訳] [DL版]',
          'A+/(DATE)] 他人になるクスリ5 +5.2 [Chinese] [四等两足牲口个人汉化] [Digital].pdf',
        ]),
      );
      final s = seriesWith(r, 'クスリ4');
      expect(s.chapters, hasLength(5));
      expect(s.author, 'DATE');
      expect(s.chapters.map((c) => c.sortNumber), [1, 4, 5, 7, 8]);
    });

    test('same author, different works stay separate', () {
      final r = recognizeLibrary(
        entries([
          'A级/(谷口さん)かしマシ1 (艦隊これくしょん -艦これ-) [中国翻訳].pdf',
          'A级/(谷口さん)かしマシ2 (艦隊これくしょん -艦これ-) [中国翻訳].pdf',
          'A级/(谷口さん) コウカン [中国翻訳] [DL版].pdf',
          'A+/(谷口さん)リモート憑依 [中国翻訳] [DL版].pdf',
          'A+/(谷口さん)君になる1.0(FateGrand Order) [中国翻訳] [DL版].pdf',
        ]),
      );
      expect(r.series, hasLength(4));
      expect(seriesWith(r, 'かしマシ1').chapters, hasLength(2));
    });

    test('same title by different authors is only a suggestion', () {
      final r = recognizeLibrary(
        entries([
          'B级/[松任知基] Exchange ～幼なじみと入れ替わり!～ 第1話 [中国翻訳].pdf',
          'B级/[松任知基] Exchange ～幼なじみと入れ替わり!～ 第2話 [中国翻訳].pdf',
          'C级/(C83) [Queen Of VANILLA (Tigusa Suzume)] Exchange (One Piece) [Chinese].pdf',
        ]),
      );
      final a = seriesWith(r, '第1話');
      final b = seriesWith(r, 'One Piece');
      expect(a, isNot(same(b)));
      expect(a.chapters, hasLength(2));
      expect(
        r.suggestions.any((s) => s.seriesIds.toSet().containsAll([a.id, b.id])),
        isTrue,
      );
    });

    test('same title without numbers is not merged automatically', () {
      final r = recognizeLibrary(
        entries(['A级/The pervert is me.pdf', 'B级/The pervert is me.pdf']),
      );
      expect(r.series, hasLength(2));
      expect(r.suggestions, hasLength(1));
    });
  });

  group('real library', () {
    test('runs fast and never merges different creators', () {
      final all = loadFixture();
      final sw = Stopwatch()..start();
      final r = recognizeLibrary(all);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      // Every entry ends up in exactly one series.
      final paths = [
        for (final s in r.series) ...s.chapters.map((c) => c.entry.path),
      ];
      expect(paths.toSet().length, paths.length);
      expect(paths.length, all.length);
      for (final s in r.series.where(
        (s) => s.confidence == Confidence.high && s.folder == null,
      )) {
        final authorSets = s.chapters
            .map((c) => c.parsed.authorKeys)
            .where((a) => a.isNotEmpty)
            .toList();
        for (final a in authorSets) {
          for (final b in authorSets) {
            expect(
              a.intersection(b),
              isNotEmpty,
              reason: 'series "${s.title}" mixes authors $a and $b',
            );
          }
        }
      }
    });

    test('without leftovers, suggestions stay few', () {
      final r = recognizeLibrary(loadFixture(withoutScrap: true));
      expect(r.suggestions.length, lessThan(30));
      expect(seriesWith(r, '狂乱の討伐姫ダリア').chapters, hasLength(7)); // 1-6 + IV
      expect(seriesWith(r, 'kaba/怪异情侣').chapters, hasLength(14));
      expect(seriesWith(r, '母愛之下').chapters.length, greaterThan(10));
    });
  });
}
