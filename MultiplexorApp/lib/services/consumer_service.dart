import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/consumer_profile.dart';
import 'manager_context.dart';

class ConsumerService {
  ConsumerService(this.context);

  final ManagerContext context;

  ConsumerProfile readActive() {
    final file = File(context.activeConsumerFile);
    if (!file.existsSync()) {
      return ConsumerProfile.plugin;
    }

    final raw = file.readAsStringSync().trim();
    return ConsumerProfile.parse(raw) ?? ConsumerProfile.plugin;
  }

  void writeActive(ConsumerProfile profile) {
    Directory(context.globalStateDir).createSync(recursive: true);
    File(context.activeConsumerFile)
      ..createSync(recursive: true)
      ..writeAsStringSync('${profile.shortName}\n');
  }

  String rootFor(ConsumerProfile profile) {
    return p.join(context.consumersRoot, profile.dirName);
  }

  void ensureConsumerDirs(ConsumerProfile profile) {
    final root = rootFor(profile);
    final dirs = <String>[
      root,
      p.join(root, 'repos'),
      p.join(root, 'builds'),
      p.join(root, 'instances'),
      p.join(root, 'state'),
      p.join(root, 'state', 'runtime'),
      p.join(root, 'state', 'build-logs'),
      p.join(root, 'dropins', 'plugins'),
      p.join(root, 'dropins', 'mods'),
    ];
    if (profile == ConsumerProfile.plugin) {
      dirs.add(p.join(root, 'shared-plugin-data', 'iris', 'packs'));
    }

    for (final dir in dirs) {
      Directory(dir).createSync(recursive: true);
    }
  }

  List<ConsumerProfile> listProfiles() {
    return ConsumerProfile.values;
  }
}
