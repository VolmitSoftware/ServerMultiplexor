import 'dart:convert';
import 'dart:io';

import 'package:multiplexor/services/storage_settings.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory metadata;

  setUp(() => metadata = Directory.systemTemp.createTempSync('storage-'));
  tearDown(() => metadata.deleteSync(recursive: true));

  File settingsFile() => File(p.join(metadata.path, 'storage.json'));

  test('downloads are not kept until the owner turns caching on', () {
    expect(StorageSettings(metadata.path).keepDownloads, isFalse);
    expect(settingsFile().existsSync(), isFalse);
  });

  test('keeping downloads saves and reads back', () {
    StorageSettings(metadata.path).saveKeepDownloads(true);

    expect(StorageSettings(metadata.path).keepDownloads, isTrue);
    expect(jsonDecode(settingsFile().readAsStringSync()), <String, Object?>{
      'schema': 1,
      'keepDownloads': true,
    });

    StorageSettings(metadata.path).saveKeepDownloads(false);

    expect(StorageSettings(metadata.path).keepDownloads, isFalse);
  });

  test('a malformed storage setting is rejected', () {
    settingsFile().writeAsStringSync('{"schema":1,"keepDownloads":"on"}');

    expect(
      () => StorageSettings(metadata.path).keepDownloads,
      throwsFormatException,
    );
  });
}
