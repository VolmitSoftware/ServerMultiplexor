import 'dart:io';

import 'package:multiplexor/utils/delete_path.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'async recursive deletion preserves shared data behind links',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'multiplexor-delete-',
      );
      try {
        final Directory shared = Directory(p.join(root.path, 'shared'))
          ..createSync();
        final File kept = File(p.join(shared.path, 'kept'))
          ..writeAsStringSync('shared');
        final Directory instance = Directory(p.join(root.path, 'instance'))
          ..createSync();
        File(p.join(instance.path, 'local')).writeAsStringSync('local');
        Link(p.join(instance.path, 'shared')).createSync(shared.path);
        await deletePath(instance.path);
        expect(instance.existsSync(), isFalse);
        expect(kept.readAsStringSync(), 'shared');
        final Link direct = Link(p.join(root.path, 'direct'))
          ..createSync(shared.path);
        await deletePath(direct.path);
        expect(direct.existsSync(), isFalse);
        expect(kept.readAsStringSync(), 'shared');
        await deletePath(instance.path);
      } finally {
        root.deleteSync(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'Symlinks require elevated Windows privileges'
        : false,
  );
}
