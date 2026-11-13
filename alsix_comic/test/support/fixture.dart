import 'dart:io';

import 'package:alsix_comic/core/recognition/library_recognizer.dart';
import 'package:alsix_comic/core/recognition/text_utils.dart';

/// Loads the real library listing. The listing holds folders and PDFs only;
/// leaf folders are image comics.
List<LibraryEntry> loadFixture({bool withoutScrap = false}) {
  final lines = File('test/fixtures/real_library_paths.txt')
      .readAsLinesSync()
      .map((l) => l.replaceAll('\\', '/').trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final parents = <String>{};
  for (final l in lines) {
    final i = l.lastIndexOf('/');
    if (i > 0) parents.add(l.substring(0, i));
  }
  final entries = <LibraryEntry>[
    for (final l in lines)
      if (l.toLowerCase().endsWith('.pdf'))
        LibraryEntry(l, EntryType.pdf)
      else if (!parents.contains(l) && l.contains('/'))
        LibraryEntry(l, EntryType.imageFolder),
  ];
  if (!withoutScrap) return entries;
  // The owner keeps image-folder leftovers of works already converted to PDF
  // and does not copy them to the phone.
  final pdfNames = {
    for (final e in entries)
      if (e.type == EntryType.pdf) matchKey(e.name),
  };
  return entries
      .where(
        (e) => e.type == EntryType.pdf || !pdfNames.contains(matchKey(e.name)),
      )
      .toList();
}
