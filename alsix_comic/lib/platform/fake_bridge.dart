import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'native_bridge.dart';

/// In-memory stand-in for the Android side. Used by tests and by the web
/// preview build, where there is no file system: pages are drawn as
/// generated pictures.
class FakeBridge implements NativeBridge {
  FakeBridge({Map<String, List<ScannedEntry>>? roots, this.pagesPerPdf = 24})
    : roots = roots ?? {};

  /// Root URI → entries currently "on disk".
  final Map<String, List<ScannedEntry>> roots;

  /// URI → content fingerprint (defaults to `size:<size>`).
  final Map<String, String> fingerprints = {};
  final int pagesPerPdf;
  PickedFolder? nextPick;
  final _volume = StreamController<String>.broadcast();
  final _docs = <int, String>{};
  var _nextDoc = 1;
  bool screenOn = false;
  bool volumeOn = false;

  void pressVolume(String dir) => _volume.add(dir);

  @override
  Future<PickedFolder?> pickFolder() async => nextPick;

  @override
  Future<List<String>> persistedRoots() async => roots.keys.toList();

  @override
  Future<void> releaseRoot(String uri) async {}

  @override
  Future<List<ScannedEntry>> scan(
    String root, {
    void Function(ScanProgress)? progress,
  }) async {
    final list = roots[root];
    if (list == null) throw StateError('No access to $root');
    progress?.call(ScanProgress(list.length, ''));
    return List.of(list);
  }

  @override
  Future<String> fingerprint(String uri) async {
    if (fingerprints.containsKey(uri)) return fingerprints[uri]!;
    for (final l in roots.values) {
      for (final e in l) {
        if (e.uri == uri) return 'size:${e.size}';
      }
    }
    throw StateError('missing $uri');
  }

  @override
  Future<List<String>> listImages(String folderUri) async {
    for (final l in roots.values) {
      for (final e in l) {
        if (e.uri == folderUri) {
          return [
            for (var i = 0; i < e.imageCount; i++) '$folderUri/${i + 1}.jpg',
          ];
        }
      }
    }
    return const [];
  }

  @override
  Future<Uint8List> readBytes(String uri) async =>
      _fakeImage(uri.hashCode, 600, 900);

  @override
  Future<PdfDocumentHandle> pdfOpen(String uri) async {
    final id = _nextDoc++;
    _docs[id] = uri;
    return PdfDocumentHandle(id, pagesPerPdf);
  }

  @override
  Future<Size> pdfPageSize(int doc, int page) async => const Size(600, 900);

  @override
  Future<RenderedPage> pdfRender(int doc, int page, int width) async {
    final w = math.max(16, width);
    final h = (w * 1.5).round();
    return RenderedPage(w, h, _pixels(_docs[doc].hashCode ^ page, page, w, h));
  }

  @override
  Future<void> pdfClose(int doc) async => _docs.remove(doc);

  @override
  Future<String?> cover(
    String uri, {
    required bool isPdf,
    required int width,
    required String out,
    int page = 0,
  }) async => null;

  @override
  Future<String> cacheDir() async => '/tmp/alsix-cache';

  @override
  Future<String> filesDir() async => '/tmp/alsix-files';

  @override
  Future<void> keepScreenOn(bool on) async => screenOn = on;

  @override
  Future<void> volumePaging(bool on) async => volumeOn = on;

  @override
  Stream<String> get volumeKeys => _volume.stream;

  // ---- Generated pictures --------------------------------------------------

  static Uint8List _pixels(int seed, int page, int w, int h) {
    final rnd = math.Random(seed);
    final hue = rnd.nextInt(360).toDouble();
    final px = Uint8List(w * h * 4);
    final (r1, g1, b1) = _hsv(hue, 0.25, 0.97);
    final (r2, g2, b2) = _hsv(hue, 0.55, 0.55);
    final panelRows = 3;
    for (var y = 0; y < h; y++) {
      final panel = (y * panelRows) ~/ h;
      final inGutter = (y % (h ~/ panelRows)) < 8 || y > h - 8;
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final border = x < 8 || x > w - 9 || inGutter;
        final split = panel == 1 && (x - w ~/ 2).abs() < 4;
        if (border || split) {
          px[i] = 255;
          px[i + 1] = 255;
          px[i + 2] = 255;
        } else {
          final t = ((x + y + panel * 37) % 97) / 97;
          px[i] = (r1 + (r2 - r1) * t).round();
          px[i + 1] = (g1 + (g2 - g1) * t).round();
          px[i + 2] = (b1 + (b2 - b1) * t).round();
        }
        px[i + 3] = 255;
      }
    }
    return px;
  }

  static (int, int, int) _hsv(double h, double s, double v) {
    final c = v * s;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = v - c;
    final (r, g, b) = switch (h ~/ 60) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    return (
      ((r + m) * 255).round(),
      ((g + m) * 255).round(),
      ((b + m) * 255).round(),
    );
  }

  /// A tiny uncompressed BMP so Image.memory can decode it anywhere.
  static Uint8List _fakeImage(int seed, int w, int h) {
    final rgba = _pixels(seed, 0, w, h);
    final rowSize = w * 4;
    final data = ByteData(54 + rowSize * h);
    data.setUint8(0, 0x42);
    data.setUint8(1, 0x4D);
    data.setUint32(2, 54 + rowSize * h, Endian.little);
    data.setUint32(10, 54, Endian.little);
    data.setUint32(14, 40, Endian.little);
    data.setInt32(18, w, Endian.little);
    data.setInt32(22, -h, Endian.little);
    data.setUint16(26, 1, Endian.little);
    data.setUint16(28, 32, Endian.little);
    var o = 54;
    for (var i = 0; i < rgba.length; i += 4) {
      data.setUint8(o++, rgba[i + 2]);
      data.setUint8(o++, rgba[i + 1]);
      data.setUint8(o++, rgba[i]);
      data.setUint8(o++, 255);
    }
    return data.buffer.asUint8List();
  }
}
