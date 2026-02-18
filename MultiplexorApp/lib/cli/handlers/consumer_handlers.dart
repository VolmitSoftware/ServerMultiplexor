import 'dart:io';

import '../../models/consumer_profile.dart';
import '../../services/app_context.dart';

Future<void> handleConsumerList() async {
  final active = consumerService.readActive();
  for (final profile in consumerService.listProfiles()) {
    if (profile == active) {
      stdout.writeln('${profile.shortName} (active)');
    } else {
      stdout.writeln(profile.shortName);
    }
  }
}

Future<void> handleConsumerShow() async {
  stdout.writeln(consumerService.readActive().shortName);
}

Future<void> handleConsumerUse(Map<String, dynamic> args) async {
  final raw = _stringArg(args, 'consumer');
  final profile = ConsumerProfile.parse(raw);

  if (profile == null) {
    stderr.writeln('Usage: consumer use <plugin|forge|fabric|neoforge>');
    exit(2);
  }

  consumerService.ensureConsumerDirs(profile);
  consumerService.writeActive(profile);

  stdout.writeln('[OK] Active consumer: ${profile.shortName}');
  stdout.writeln('[INFO] Consumer root: ${consumerService.rootFor(profile)}');
}

Future<void> handleConsumerPath() async {
  final active = appContext.requestedConsumer ?? consumerService.readActive();
  stdout.writeln(consumerService.rootFor(active));
}

String? _stringArg(Map<String, dynamic> args, String name) {
  final value = args[name];
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return null;
  }
  return text;
}
