import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class StorageSettings {
  StorageSettings(String metadataDirectory)
    : file = File(p.join(metadataDirectory, 'storage.json'));

  final File file;

  bool get keepDownloads {
    if (!file.existsSync()) {
      return false;
    }
    final Object? json = jsonDecode(file.readAsStringSync());
    if (json is! Map<String, Object?> || json['schema'] != 1) {
      throw FormatException('Invalid storage settings: ${file.path}');
    }
    return switch (json['keepDownloads']) {
      null => false,
      bool keep => keep,
      _ => throw FormatException(
        'Keep downloads cached must be on or off: ${file.path}',
      ),
    };
  }

  void saveKeepDownloads(bool keep) {
    file.parent.createSync(recursive: true);
    final File temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(
      '${jsonEncode(<String, Object?>{'schema': 1, 'keepDownloads': keep})}\n',
      flush: true,
    );
    temporary.renameSync(file.path);
  }
}
