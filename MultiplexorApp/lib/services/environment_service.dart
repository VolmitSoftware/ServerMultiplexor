import 'dart:io';

import '../models/consumer_profile.dart';
import 'consumer_service.dart';
import 'manager_context.dart';

class EnvironmentService {
  EnvironmentService({required this.context, required this.consumerService});

  final ManagerContext context;
  final ConsumerService consumerService;

  void bootstrap() {
    Directory(context.rootDir).createSync(recursive: true);
    Directory(context.metadataDir).createSync(recursive: true);
    Directory(context.globalStateDir).createSync(recursive: true);
    Directory(context.consumersRoot).createSync(recursive: true);

    for (final profile in consumerService.listProfiles()) {
      consumerService.ensureConsumerDirs(profile);
    }

    final activeFile = File(context.activeConsumerFile);
    if (!activeFile.existsSync()) {
      consumerService.writeActive(context.requestedConsumer ?? ConsumerProfile.plugin);
    }

    _writeWorkspaceConfigIfMissing();
  }

  void _writeWorkspaceConfigIfMissing() {
    final config = File(context.workspaceConfigFile);
    if (config.existsSync()) {
      return;
    }

    config.createSync(recursive: true);
    config.writeAsStringSync(
      [
        'schema_version: 1',
        "created_at_utc: '${DateTime.now().toUtc().toIso8601String()}'",
        "tool: 'multiplexor'",
      ].join('\n'),
    );
  }
}
