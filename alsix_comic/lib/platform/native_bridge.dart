import 'dart:async';

import 'package:flutter/services.dart';

/// A readable item reported by a scan.
class ScannedEntry {
  const ScannedEntry({
    required this.path,
    required this.isPdf,
    required this.uri,
    required this.size,
    required this.modified,
    this.imageCount = 0,
    this.firstImage,
  });

  /// Path relative to the library root, '/' separated.
  final String path;
  final bool isPdf;

  /// Document URI (content://…) or absolute file path.
  final String uri;
  final int size;
  final int modified;
  final int imageCount;
  final String? firstImage;

  factory ScannedEntry.fromMap(Map<Object?, Object?> m) => ScannedEntry(
    path: m['path'] as String,
    isPdf: m['type'] == 'pdf',
    uri: m['uri'] as String,
    size: (m['size'] as num?)?.toInt() ?? 0,
    modified: (m['modified'] as num?)?.toInt() ?? 0,
    imageCount: (m['imageCount'] as num?)?.toInt() ?? 0,
    firstImage: m['firstImage'] as String?,
  );
}

class ScanProgress {
  const ScanProgress(this.count, this.dir);
  final int count;
  final String dir;
}

class PickedFolder {
  const PickedFolder(this.uri, this.name);
  final String uri;
  final String name;
}

class PdfDocumentHandle {
  const PdfDocumentHandle(this.id, this.pageCount);
  final int id;
  final int pageCount;
}

class RenderedPage {
  const RenderedPage(this.width, this.height, this.pixels);
  final int width;
  final int height;

  /// RGBA8888 pixels.
  final Uint8List pixels;
}

/// Everything the app needs from the operating system.
abstract class NativeBridge {
  Future<PickedFolder?> pickFolder();
  Future<List<String>> persistedRoots();
  Future<void> releaseRoot(String uri);

  /// Scans a root; progress is reported on [progress] while it runs.
  Future<List<ScannedEntry>> scan(
    String root, {
    void Function(ScanProgress)? progress,
  });
  Future<String> fingerprint(String uri);
  Future<List<String>> listImages(String folderUri);
  Future<Uint8List> readBytes(String uri);

  Future<PdfDocumentHandle> pdfOpen(String uri);
  Future<Size> pdfPageSize(int doc, int page);
  Future<RenderedPage> pdfRender(int doc, int page, int width);
  Future<void> pdfClose(int doc);

  /// Writes a JPEG cover to [out]; returns null when the item has no pages.
  Future<String?> cover(
    String uri, {
    required bool isPdf,
    required int width,
    required String out,
    int page = 0,
  });
  Future<String> cacheDir();
  Future<String> filesDir();

  Future<void> keepScreenOn(bool on);
  Future<void> volumePaging(bool on);

  /// Emits "next" / "previous" when a volume key is pressed while paging is on.
  Stream<String> get volumeKeys;
}

/// Implementation backed by the Kotlin code in MainActivity.
class MethodChannelBridge implements NativeBridge {
  MethodChannelBridge() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel('alsix/native');
  final _volume = StreamController<String>.broadcast();
  final _progressListeners = <int, void Function(ScanProgress)>{};
  var _scanIds = 0;

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'volumeKey':
        _volume.add(call.arguments as String);
      case 'scanProgress':
        final m = call.arguments as Map<Object?, Object?>;
        _progressListeners[m['scanId'] as int]?.call(
          ScanProgress(m['count'] as int, m['dir'] as String),
        );
    }
    return null;
  }

  @override
  Future<PickedFolder?> pickFolder() async {
    final r = await _channel.invokeMapMethod<String, Object?>('pickFolder');
    if (r == null) return null;
    return PickedFolder(r['uri'] as String, r['name'] as String);
  }

  @override
  Future<List<String>> persistedRoots() async =>
      (await _channel.invokeListMethod<String>('persistedRoots')) ?? const [];

  @override
  Future<void> releaseRoot(String uri) =>
      _channel.invokeMethod('releaseRoot', {'uri': uri});

  @override
  Future<List<ScannedEntry>> scan(
    String root, {
    void Function(ScanProgress)? progress,
  }) async {
    final id = ++_scanIds;
    if (progress != null) _progressListeners[id] = progress;
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('scan', {
        'root': root,
        'scanId': id,
      });
      final list = (r!['entries'] as List).cast<Map<Object?, Object?>>();
      return [for (final m in list) ScannedEntry.fromMap(m)];
    } finally {
      _progressListeners.remove(id);
    }
  }

  @override
  Future<String> fingerprint(String uri) async =>
      (await _channel.invokeMethod<String>('fingerprint', {'uri': uri}))!;

  @override
  Future<List<String>> listImages(String folderUri) async =>
      (await _channel.invokeListMethod<String>('listImages', {
        'uri': folderUri,
      })) ??
      const [];

  @override
  Future<Uint8List> readBytes(String uri) async =>
      (await _channel.invokeMethod<Uint8List>('readBytes', {'uri': uri}))!;

  @override
  Future<PdfDocumentHandle> pdfOpen(String uri) async {
    final r = await _channel.invokeMapMethod<String, Object?>('pdfOpen', {
      'uri': uri,
    });
    return PdfDocumentHandle(r!['doc'] as int, r['pages'] as int);
  }

  @override
  Future<Size> pdfPageSize(int doc, int page) async {
    final r = await _channel.invokeListMethod<int>('pdfPageSize', {
      'doc': doc,
      'page': page,
    });
    return Size(r![0].toDouble(), r[1].toDouble());
  }

  @override
  Future<RenderedPage> pdfRender(int doc, int page, int width) async {
    final r = await _channel.invokeMapMethod<String, Object?>('pdfRender', {
      'doc': doc,
      'page': page,
      'width': width,
    });
    return RenderedPage(
      r!['width'] as int,
      r['height'] as int,
      r['pixels'] as Uint8List,
    );
  }

  @override
  Future<void> pdfClose(int doc) =>
      _channel.invokeMethod('pdfClose', {'doc': doc});

  @override
  Future<String?> cover(
    String uri, {
    required bool isPdf,
    required int width,
    required String out,
    int page = 0,
  }) => _channel.invokeMethod<String>('cover', {
    'uri': uri,
    'type': isPdf ? 'pdf' : 'images',
    'width': width,
    'out': out,
    'page': page,
  });

  @override
  Future<String> cacheDir() async =>
      (await _channel.invokeMethod<String>('cacheDir'))!;

  @override
  Future<String> filesDir() async =>
      (await _channel.invokeMethod<String>('filesDir'))!;

  @override
  Future<void> keepScreenOn(bool on) =>
      _channel.invokeMethod('keepScreenOn', {'on': on});

  @override
  Future<void> volumePaging(bool on) =>
      _channel.invokeMethod('volumePaging', {'on': on});

  @override
  Stream<String> get volumeKeys => _volume.stream;
}
