import 'dart:io';

/// Removes the entry itself without following directory links. Async IO lets
/// independent instance deletions proceed while a large world is being removed.
Future<void> deletePath(String path) async {
  for (int attempt = 1; attempt <= 3; attempt++) {
    try {
      switch (await FileSystemEntity.type(path, followLinks: false)) {
        case FileSystemEntityType.directory:
          await Directory(path).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(path).delete();
        case FileSystemEntityType.notFound:
          return;
        default:
          await File(path).delete();
      }
      return;
    } on FileSystemException {
      if (attempt == 3) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 75 * attempt));
    }
  }
}
