import 'package:alsix_comic/data/database.dart';
import 'package:alsix_comic/data/library_repository.dart';
import 'package:alsix_comic/data/library_sync.dart';
import 'package:alsix_comic/platform/fake_bridge.dart';
import 'package:alsix_comic/platform/native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const root = 'content://tree/comics';

ScannedEntry pdf(String path, {int size = 1000}) => ScannedEntry(
  path: path,
  isPdf: true,
  uri: 'uri:$path',
  size: size,
  modified: 1,
);

ScannedEntry images(String path, {int count = 20}) => ScannedEntry(
  path: path,
  isPdf: false,
  uri: 'uri:$path',
  size: count * 100,
  modified: 1,
  imageCount: count,
);

class Harness {
  Harness(this.db, this.native)
    : sync = LibrarySync(db, native),
      repo = LibraryRepository(db);

  final AppDatabase db;
  final FakeBridge native;
  final LibrarySync sync;
  final LibraryRepository repo;

  static Future<Harness> create(List<ScannedEntry> files) async {
    sqfliteFfiInit();
    final db = await AppDatabase.open(
      inMemoryDatabasePath,
      factory: databaseFactoryFfiNoIsolate,
    );
    final h = Harness(db, FakeBridge(roots: {root: files}));
    await h.repo.addRoot(root, 'comics');
    return h;
  }

  List<ScannedEntry> get files => native.roots[root]!;

  Future<SyncReport> rescan() => sync.syncAll();
  Future<LibrarySnapshot> load() => repo.load();

  Future<SeriesView> seriesOf(String pathPart) async {
    final snap = await load();
    return snap.series.firstWhere(
      (s) => s.chapters.any((c) => c.path.contains(pathPart)),
    );
  }

  Future<ChapterView> chapter(String pathPart) async {
    final snap = await load();
    return snap.series
        .expand((s) => s.chapters)
        .firstWhere((c) => c.path.contains(pathPart));
  }
}

void main() {
  late Harness h;

  setUp(() async {
    h = await Harness.create([
      pdf('A级/[作者] 龙王的工作1.pdf', size: 101),
      pdf('A级/[作者] 龙王的工作2.pdf', size: 102),
      pdf('A级/[作者] 龙王的工作3.pdf', size: 103),
      pdf('A级/独立作品.pdf', size: 200),
      images('已审核/图片漫画 第1話'),
    ]);
  });

  tearDown(() => h.db.close());

  test('first scan creates series and chapters', () async {
    final report = await h.rescan();
    expect(report.added, 5);
    final snap = await h.load();
    expect(snap.series, hasLength(3));
    final s = await h.seriesOf('龙王的工作1');
    expect(s.title, '龙王的工作');
    expect(s.chapters.map((c) => c.fileName), [
      '[作者] 龙王的工作1.pdf',
      '[作者] 龙王的工作2.pdf',
      '[作者] 龙王的工作3.pdf',
    ]);
    expect(s.author, '作者');
  });

  test('rescan without changes keeps progress and reports nothing', () async {
    await h.rescan();
    final c = await h.chapter('龙王的工作2');
    await h.repo.saveProgress(c.id, page: 9, pageCount: 30);
    final report = await h.rescan();
    expect(report.hasChanges, isFalse);
    final after = await h.chapter('龙王的工作2');
    expect(after.id, c.id);
    expect(after.lastPage, 9);
    expect(after.pageCount, 30);
  });

  test('moved file keeps its history', () async {
    await h.rescan();
    final c = await h.chapter('独立作品');
    await h.repo.saveProgress(c.id, page: 5, pageCount: 10);
    h.files.removeWhere((e) => e.path == 'A级/独立作品.pdf');
    h.files.add(pdf('B级/独立作品.pdf', size: 200));
    final report = await h.rescan();
    expect(report.moved, 1);
    expect(report.added, 0);
    final after = await h.chapter('独立作品');
    expect(after.id, c.id);
    expect(after.path, 'B级/独立作品.pdf');
    expect(after.lastPage, 5);
  });

  test('renamed PDF is recognised by its content fingerprint', () async {
    await h.rescan();
    await h.sync.fillFingerprints();
    final c = await h.chapter('独立作品');
    await h.repo.saveProgress(c.id, page: 3, pageCount: 10);
    h.files.removeWhere((e) => e.path == 'A级/独立作品.pdf');
    h.files.add(pdf('A级/改名后的作品.pdf', size: 200));
    final report = await h.rescan();
    expect(report.moved, 1);
    final after = await h.chapter('改名后的作品');
    expect(after.id, c.id);
    expect(after.lastPage, 3);
  });

  test(
    'deleted file is kept as missing and restored when it returns',
    () async {
      await h.rescan();
      final c = await h.chapter('独立作品');
      await h.repo.saveProgress(c.id, page: 7, pageCount: 10);
      final removed = h.files.firstWhere((e) => e.path == 'A级/独立作品.pdf');
      h.files.remove(removed);
      expect((await h.rescan()).removed, 1);
      expect((await h.load()).series.where((s) => s.allMissing), hasLength(1));
      h.files.add(removed);
      expect((await h.rescan()).restored, 1);
      final after = await h.chapter('独立作品');
      expect(after.missing, isFalse);
      expect(after.lastPage, 7);
    },
  );

  test('modified file keeps progress but resets page count', () async {
    await h.rescan();
    final c = await h.chapter('龙王的工作3');
    await h.repo.saveProgress(c.id, page: 2, pageCount: 20);
    final i = h.files.indexWhere((e) => e.path.contains('龙王的工作3'));
    h.files[i] = pdf(h.files[i].path, size: 999);
    expect((await h.rescan()).modified, 1);
    final after = await h.chapter('龙王的工作3');
    expect(after.lastPage, 2);
    expect(after.pageCount, isNull);
    expect(after.coverVersion, c.coverVersion + 1);
  });

  test('manual series title survives rescans and regrouping', () async {
    await h.rescan();
    final single = await h.seriesOf('独立作品');
    await h.repo.renameSeries(single.id, '我改的名字');
    await h.rescan();
    expect((await h.seriesOf('独立作品')).title, '我改的名字');
    // A second chapter appears: the auto key changes, the name must stay.
    h.files.add(pdf('A级/独立作品2.pdf', size: 201));
    await h.rescan();
    final s = await h.seriesOf('独立作品.pdf');
    expect(s.chapters, hasLength(2));
    expect(s.title, '我改的名字');
    expect(s.id, single.id);
  });

  test('merge and move survive rescans', () async {
    await h.rescan();
    final a = await h.seriesOf('龙王的工作1');
    final b = await h.seriesOf('独立作品');
    await h.repo.mergeSeries([b.id], a.id);
    await h.rescan();
    expect((await h.seriesOf('独立作品')).id, a.id);
    expect((await h.seriesOf('龙王的工作1')).chapters, hasLength(4));

    final img = await h.chapter('图片漫画');
    final newId = await h.repo.splitSeries([img.id], '新系列');
    await h.rescan();
    final s = await h.seriesOf('图片漫画');
    expect(s.id, newId);
    expect(s.title, '新系列');
  });

  test('chapter order and number overrides', () async {
    await h.rescan();
    final s = await h.seriesOf('龙王的工作1');
    final ids = s.chapters.map((c) => c.id).toList().reversed.toList();
    await h.repo.reorderChapters(ids);
    await h.rescan();
    expect((await h.seriesOf('龙王的工作1')).chapters.map((c) => c.id), ids);
  });

  test('ignored folder is skipped by later scans', () async {
    await h.rescan();
    final root = (await h.load()).roots.single;
    await h.repo.ignoreFolder(root.id, '已审核');
    h.files.add(images('已审核/另一个图片漫画'));
    final report = await h.rescan();
    expect(report.added, 0);
    final snap = await h.load();
    expect(
      snap.series.any((s) => s.chapters.any((c) => c.path.startsWith('已审核'))),
      isFalse,
    );
    await h.repo.unignore(root.id, '已审核');
    await h.rescan();
    expect(
      (await h.load()).series.where(
        (s) => s.chapters.any((c) => c.path.startsWith('已审核')),
      ),
      hasLength(2),
    );
  });

  test('suggestions can be dismissed for good', () async {
    h.files
      ..add(pdf('A级/[甲] Exchange 1.pdf', size: 301))
      ..add(pdf('C级/[乙] Exchange.pdf', size: 302));
    await h.rescan();
    var snap = await h.load();
    expect(snap.suggestions, hasLength(1));
    await h.repo.dismissSuggestion(snap.suggestions.single);
    await h.rescan();
    snap = await h.load();
    expect(snap.suggestions, isEmpty);
  });

  test('accepting a suggestion merges the series', () async {
    h.files
      ..add(pdf('A级/The pervert is me.pdf', size: 401))
      ..add(pdf('B级/The pervert is me.pdf', size: 402));
    await h.rescan();
    var snap = await h.load();
    final target = await h.repo.acceptSuggestion(snap, snap.suggestions.single);
    await h.rescan();
    snap = await h.load();
    expect(snap.suggestions, isEmpty);
    expect(snap.byId[target]!.chapters, hasLength(2));
  });

  test('folder role makes a series', () async {
    h.files
      ..add(pdf('长篇/HUNT/开端.pdf', size: 501))
      ..add(pdf('长篇/HUNT/追猎.pdf', size: 502));
    await h.rescan();
    expect((await h.seriesOf('开端')).chapters, hasLength(1));
    final root = (await h.load()).roots.single;
    await h.repo.setFolderRole(root.id, '长篇/HUNT', 'series');
    await h.rescan();
    final s = await h.seriesOf('开端');
    expect(s.title, 'HUNT');
    expect(s.chapters, hasLength(2));
  });

  test('progress, continue chapter and new chapters', () async {
    await h.rescan();
    var s = await h.seriesOf('龙王的工作1');
    expect(s.unread, isTrue);
    await h.repo.saveProgress(s.chapters[0].id, page: 29, pageCount: 30);
    s = await h.seriesOf('龙王的工作1');
    expect(s.chapters[0].finished, isTrue);
    expect(s.continueChapter!.id, s.chapters[1].id);
    expect(s.unread, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    h.files.add(pdf('A级/[作者] 龙王的工作4.pdf', size: 104));
    await h.rescan();
    s = await h.seriesOf('龙王的工作1');
    expect(s.hasNewChapter, isTrue);
  });
}
