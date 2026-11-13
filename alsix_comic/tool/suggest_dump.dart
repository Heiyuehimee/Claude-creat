import 'dart:io';

import 'package:alsix_comic/core/recognition/library_recognizer.dart';

import '../test/support/fixture.dart' as t;

void main() {
  final r = recognizeLibrary(t.loadFixture(withoutScrap: true));
  final byId = {for (final s in r.series) s.id: s};
  stdout.writeln(
    'series ${r.series.length}, multi ${r.series.where((s) => s.chapters.length > 1).length}, suggestions ${r.suggestions.length}, uncertain ${r.series.where((s) => s.hasUncertainChapter).length}',
  );
  for (final g in r.suggestions) {
    stdout.writeln('-- ${g.reason}');
    for (final id in g.seriesIds) {
      stdout.writeln(
        '     ${byId[id]!.title}  <- ${byId[id]!.chapters.first.entry.path}',
      );
    }
  }
}
