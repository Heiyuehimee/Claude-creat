import 'package:alsix_comic/core/recognition/title_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void expectChapter(
  String name,
  String series,
  double? number, {
  double? end,
  ChapterKind kind = ChapterKind.normal,
}) {
  final p = parseTitle(name);
  expect(p.seriesTitle, series, reason: 'series of "$name"');
  expect(p.chapter.number, number, reason: 'number of "$name"');
  if (end != null) expect(p.chapter.numberEnd, end, reason: 'end of "$name"');
  expect(p.chapter.kind, kind, reason: 'kind of "$name"');
}

void main() {
  group('noise removal and creators', () {
    test('circle and author', () {
      final p = parseTitle(
        '[Senpenbankashiki (DATE)] 他人になるクスリ4 [Chinese] [熊崎玉子汉化组]',
      );
      expect(p.circle, 'Senpenbankashiki');
      expect(p.authors, ['DATE']);
      expect(p.seriesTitle, '他人になるクスリ');
      expect(p.notes, containsAll(['Chinese', '熊崎玉子汉化组']));
    });

    test('event then circle', () {
      final p = parseTitle(
        '(C92) [Kitsune (Tachikawa Negoro)] Zetaraga Irekawatteru! 澤塔與拉卡交換了身體! (Granblue Fantasy) [Chinese]',
      );
      expect(p.event, 'C92');
      expect(p.circle, 'Kitsune');
      expect(p.source, 'Granblue Fantasy');
    });

    test('author in leading parentheses', () {
      final p = parseTitle('(谷口さん)リモート憑依 [中国翻訳] [DL版]');
      expect(p.authors, ['谷口さん']);
      expect(p.seriesTitle, 'リモート憑依');
    });

    test('broken leading bracket', () {
      final p = parseTitle(
        '(DATE)] 他人になるクスリ5 +5.2 [Chinese] [四等两足牲口个人汉化] [Digital]',
      );
      expect(p.authors, ['DATE']);
      expectChapter('(DATE)] 他人になるクスリ5 +5.2 [Chinese]', '他人になるクスリ', 5);
    });

    test('multiple authors', () {
      final p = parseTitle(
        '[Popland (Fanta no Cola Aji, Hiiragi Popura)] Nikutai Dorobou no Udewa 窈取肉體的手鐲 [Chinese]',
      );
      expect(p.authors, ['Fanta no Cola Aji', 'Hiiragi Popura']);
      expect(p.seriesTitle, 'Nikutai Dorobou no Udewa 窈取肉體的手鐲');
    });

    test('magazine and page count are noise', () {
      expect(
        parseTitle(
          '[Yomoyama Akira] Premium Service (COMIC Masyo 2019-08) [Chinese]',
        ).seriesTitle,
        'Premium Service',
      );
      expectChapter('母愛之下10 (12P)', '母愛之下', 10);
    });

    test('E-Hentai suffix and underscores', () {
      expect(
        parseTitle('[RAIN]_桃绿色的圆舞曲_[AI_Generated]_-_E-Hentai_Galleries.3833902')
            .seriesTitle,
        '桃绿色的圆舞曲',
      );
    });

    test('whole name in brackets', () {
      expect(parseTitle('【推しの皮】').seriesTitle, '推しの皮');
    });

    test('full-width characters', () {
      expectChapter('[マリアライト] 入れかわりシンデレラ５[中国翻訳]', '入れかわりシンデレラ', 5);
    });
  });

  group('chapter numbers', () {
    test('trailing numbers', () {
      expectChapter('龙王的工作3', '龙王的工作', 3);
      expectChapter('主管的秘密01', '主管的秘密', 1);
      expectChapter('[おでんオーガン (ツリサス)] Holy Bitch 1 [中国翻訳]', 'Holy Bitch', 1);
    });

    test('version style numbers', () {
      expectChapter('(谷口さん)君になる1.0(FateGrand Order) [中国翻訳]', '君になる', 1.0);
      expectChapter('(谷口さん)君になる1.5 -玉藻の前-(FateGrand Order)', '君になる', 1.5);
      expectChapter('(谷口さん)君になる2.0-ジャンヌ・ダルク- (FateGrand Order)', '君になる', 2.0);
      expectChapter('(谷口さん)君になる2.1～ジャンヌ・オルタ～ (FateGrand Order)', '君になる', 2.1);
    });

    test('main number with appended part', () {
      expectChapter('[千変万化式 (DATE)] 他人になるクスリ7 + 7.2 [中国翻訳]', '他人になるクスリ', 7);
    });

    test('explicit markers', () {
      expectChapter(
        '[松任知基] Exchange ～幼なじみと入れ替わり!～ 第11話 [中国翻訳]',
        'Exchange',
        11,
      );
      expectChapter('(谷口さん)放課後の鏡像怪異1枚目', '放課後の鏡像怪異', 1);
      expectChapter(
        '[水心天羅] 入れ替ってドタバタえっち!～綾姉のビンカンな身体に俺は耐えられない 1巻 [中国翻訳]',
        '入れ替ってドタバタえっち',
        1,
      );
      expectChapter(
        '[にゅう工房 (セガーレ井尻)] 対影特殊部隊 下級男性職員の日常EX1 第一话 [中国翻訳]',
        '対影特殊部隊 下級男性職員の日常',
        1,
      );
    });

    test('ranges', () {
      expectChapter('[DATE] 改変対象 第1-4話  [洨五組]', '改変対象', 1, end: 4);
      expectChapter('[KABA] 染指 1-4', '染指', 1, end: 4);
      expectChapter('[泪吉] 我的寄生兽妈妈1-2 中文', '我的寄生兽妈妈', 1, end: 2);
      expectChapter(
        '[Hinaki] Kukkorose no Himekishi to nari Ch 1-30 [Chinese]',
        'Kukkorose no Himekishi to nari',
        1,
        end: 30,
      );
    });

    test('parts', () {
      expectChapter('媽媽的味道-上', '媽媽的味道', 1);
      expectChapter('媽媽的味道-下', '媽媽的味道', 2);
      expectChapter(
        '[朝賀えり] 絶倫！？入れ替わり性生活【中編】 (COMIC真激2026年4月号)',
        '絶倫!?入れ替わり性生活',
        1.5,
      );
    });

    test('number glued to title followed by subtitle', () {
      expectChapter(
        '(C92) [Argyle◇check (こまめ丸)] とろ娘13 チノちゃんはじめました!!',
        'とろ娘',
        13,
      );
    });

    test('numbers that are not chapters', () {
      expectChapter(
        '[Orikawa] 女の体になった俺は男子校の修学旅行で、同級生30人（+担任）全員とヤリました。 (1) [Chinese]',
        '女の体になった俺は男子校の修学旅行で、同級生30人 全員とヤリました',
        1,
      );
      expectChapter(
        '(C92) [ZUZUZU (Kamiya Zuzu)] 300の御印あつめて交換するよりカワイイアニラになった方がいい',
        '300の御印あつめて交換するよりカワイイアニラになった方がいい',
        null,
      );
    });

    test('variant labels', () {
      final p = parseTitle('邻家的天使大人4（好分支）');
      expect(p.seriesTitle, '邻家的天使大人');
      expect(p.chapter.number, 4);
      expect(p.chapter.label, '好分支');
      expect(parseTitle('主管的秘密2(手繪)').chapter.label, '手繪');
    });
  });

  group('special chapters', () {
    test('compilation', () {
      expectChapter(
        '(谷口さん)君になる総集編 ゲスト様(FateGrand Order) [中国翻訳]',
        '君になる',
        null,
        kind: ChapterKind.compilation,
      );
    });

    test('named arc', () {
      expectChapter(
        '(谷口さん)君になる～美遊編～ (Fatekaleid liner プリズマ☆イリヤ)',
        '君になる',
        null,
        kind: ChapterKind.extra,
      );
    });

    test('side story', () {
      expectChapter(
        '[憑依ラヴァー (Duokuma)] そのカラダ、お持ち帰りで Side藤城李恵 [中国語]',
        'そのカラダ、お持ち帰りで',
        null,
        kind: ChapterKind.extra,
      );
    });

    test('main story bundled with an extra stays normal', () {
      expectChapter('師弟的復仇 1-3+番外 [換身附身奪舍]', '師弟的復仇', 1, end: 3);
      expectChapter('[dofib] 黒之受肉+后日谈 [Chinese]', '黒之受肉', null);
      expectChapter('换身卡芙卡+DLC [Chinese] [Starpt个人汉化]', '换身卡芙卡', null);
    });
  });
}
