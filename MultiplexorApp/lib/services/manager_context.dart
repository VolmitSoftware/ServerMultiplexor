import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/consumer_profile.dart';

class ManagerContext {
  ManagerContext({
    required this.rootDir,
    required this.verbose,
    this.requestedConsumer,
  });

  final String rootDir;
  final bool verbose;
  final ConsumerProfile? requestedConsumer;
  String get consumersRoot => p.join(rootDir, 'consumers');
  String get globalStateDir => p.join(rootDir, '.manager-state');
  String get metadataDir => p.join(rootDir, '.multiplexor');
  String get workspaceConfigFile => p.join(metadataDir, 'workspace.yaml');
  String get activeConsumerFile =>
      p.join(globalStateDir, 'active-consumer.txt');
  bool get hasLegacyBackend => false;

  static String detectRoot({String? startFrom, String? explicitRoot}) {
    if (explicitRoot != null && explicitRoot.trim().isNotEmpty) {
      return _canonicalizeDir(explicitRoot);
    }

    final origin = _canonicalizeDir(startFrom ?? Directory.current.path);
    Directory dir = Directory(origin);

    while (true) {
      if (_looksLikeWorkspace(dir.path)) {
        return dir.path;
      }

      final parent = dir.parent;
      if (parent.path == dir.path) {
        break;
      }

      dir = parent;
    }

    // No existing workspace found. Treat current working directory as the root.
    return origin;
  }

  static bool _looksLikeWorkspace(String dirPath) {
    final marker = File(p.join(dirPath, '.multiplexor', 'workspace.yaml'));
    if (marker.existsSync()) {
      return true;
    }

    final activeConsumer = File(
      p.join(dirPath, '.manager-state', 'active-consumer.txt'),
    );
    if (activeConsumer.existsSync()) {
      return true;
    }

    final consumers = Directory(p.join(dirPath, 'consumers'));
    final globalState = Directory(p.join(dirPath, '.manager-state'));
    if (consumers.existsSync() && globalState.existsSync()) {
      return true;
    }

    final app = Directory(p.join(dirPath, 'MultiplexorApp'));
    return app.existsSync() && consumers.existsSync();
  }

  static String _canonicalizeDir(String rawPath) {
    final dir = Directory(rawPath);
    if (dir.existsSync()) {
      return dir.resolveSymbolicLinksSync();
    }
    return p.normalize(p.absolute(rawPath));
  }

  List<String> injectConsumer(List<String> args) {
    if (args.isEmpty || requestedConsumer == null) {
      return args;
    }

    if (args.first == 'consumer') {
      return args;
    }

    final hasConsumerFlag = args.any(
      (e) => e == '--consumer' || e.startsWith('--consumer='),
    );
    if (hasConsumerFlag) {
      return args;
    }

    return <String>['--consumer', requestedConsumer!.shortName, ...args];
  }
}
