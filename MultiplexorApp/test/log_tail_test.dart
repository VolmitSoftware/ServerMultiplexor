import 'dart:io';

import 'package:multiplexor/services/monitor/log_tail.dart';
import 'package:test/test.dart';

void main() {
  group('tailLines', () {
    test('returns the last maxLines lines', () {
      expect(tailLines('a\nb\nc\nd\n', 2), <String>['c', 'd']);
    });

    test('returns every line when the text is shorter than maxLines', () {
      expect(tailLines('a\nb\nc', 10), <String>['a', 'b', 'c']);
    });

    test('drops only the final line terminator, not blank lines', () {
      expect(tailLines('a\n\n', 5), <String>['a', '']);
    });

    test('strips carriage returns from CRLF text', () {
      expect(tailLines('a\r\nb\r\n', 2), <String>['a', 'b']);
    });

    test('returns an empty list for empty text', () {
      expect(tailLines('', 5), isEmpty);
    });

    test('returns an empty list when maxLines is zero or negative', () {
      expect(tailLines('a\nb\n', 0), isEmpty);
      expect(tailLines('a\nb\n', -3), isEmpty);
    });
  });

  group('readLogTail', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('log-tail-test');
    });

    tearDown(() {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test('reads the trailing lines of a real file', () async {
      final File file = File('${dir.path}/server.log');
      file.writeAsStringSync('one\ntwo\nthree\nfour\n');

      expect(await readLogTail(file.path, 2), <String>['three', 'four']);
    });

    test('reads only the trailing window of a large file', () async {
      final File file = File('${dir.path}/big.log');
      final StringBuffer buffer = StringBuffer();
      for (int i = 0; i < 20000; i++) {
        buffer.writeln('line $i padded out so the file exceeds the window');
      }
      file.writeAsStringSync(buffer.toString());

      final List<String> tail = await readLogTail(file.path, 3);
      expect(tail, <String>[
        'line 19997 padded out so the file exceeds the window',
        'line 19998 padded out so the file exceeds the window',
        'line 19999 padded out so the file exceeds the window',
      ]);
    });

    test(
      'reports unavailability instead of throwing for a missing file',
      () async {
        expect(await readLogTail('${dir.path}/absent.log', 5), <String>[
          '<log unavailable>',
        ]);
      },
    );

    test('reports unavailability for a directory path', () async {
      expect(await readLogTail(dir.path, 5), <String>['<log unavailable>']);
    });
  });
}
