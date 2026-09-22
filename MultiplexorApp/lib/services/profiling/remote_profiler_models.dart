import 'dart:convert';

import 'package:crypto/crypto.dart';

final class RemoteProfilerTarget {
  const RemoteProfilerTarget({
    required this.id,
    required this.uuid,
    required this.name,
    required this.profileId,
    required this.nodeId,
  });

  final String id;
  final String uuid;
  final String name;
  final String profileId;
  final int nodeId;

  String get key =>
      sha256.convert(utf8.encode('$profileId\u0000$uuid')).toString();

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'uuid': uuid,
    'name': name,
    'profileId': profileId,
    'nodeId': nodeId,
  };

  factory RemoteProfilerTarget.fromJson(Map<String, Object?> json) =>
      RemoteProfilerTarget(
        id: json['id'] as String,
        uuid: json['uuid'] as String,
        name: json['name'] as String,
        profileId: json['profileId'] as String,
        nodeId: json['nodeId'] as int,
      );
}

final class RemoteProfilerOptions {
  const RemoteProfilerOptions({
    required this.agentDirectory,
    this.configPath,
    this.duration = const Duration(seconds: 120),
    this.live = false,
    this.sessionId = 1,
    this.port = 8849,
    this.restart = false,
    this.attach = false,
  });

  final String agentDirectory;
  final String? configPath;
  final Duration duration;
  final bool live;
  final int sessionId;
  final int port;
  final bool restart;
  final bool attach;

  void validate() {
    if (attach && restart) {
      throw ArgumentError('Attach cannot be combined with restart.');
    }
    if (agentDirectory.trim().isEmpty ||
        duration.inSeconds < 1 ||
        duration.inSeconds > 86400 ||
        sessionId < 1 ||
        port < 1 ||
        port > 65535) {
      throw ArgumentError(
        'Provide an agent directory, duration of 1–86400 seconds, positive session ID, and valid port.',
      );
    }
  }
}

final class RemoteProfilerCheck {
  const RemoteProfilerCheck({
    required this.target,
    required this.javaVersion,
    required this.os,
    required this.architecture,
    required this.startupCommand,
    required this.isRunning,
    this.issues = const <String>[],
  });

  final RemoteProfilerTarget target;
  final String javaVersion;
  final String os;
  final String architecture;
  final String startupCommand;
  final bool isRunning;
  final List<String> issues;
  bool get ready => issues.isEmpty;
}

final class RemoteProfilerStage {
  const RemoteProfilerStage({
    required this.startupCommand,
    required this.remoteDirectory,
    required this.snapshotPath,
    required this.agentArgument,
    this.logDurationSeconds = 420,
  });

  final String startupCommand;
  final String remoteDirectory;
  final String snapshotPath;
  final String agentArgument;
  final int logDurationSeconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'startupCommand': startupCommand,
    'remoteDirectory': remoteDirectory,
    'snapshotPath': snapshotPath,
    'agentArgument': agentArgument,
    'logDurationSeconds': logDurationSeconds,
  };

  factory RemoteProfilerStage.fromJson(Map<String, Object?> json) =>
      RemoteProfilerStage(
        startupCommand: json['startupCommand'] as String,
        remoteDirectory: json['remoteDirectory'] as String,
        snapshotPath: json['snapshotPath'] as String,
        agentArgument: json['agentArgument'] as String,
        logDurationSeconds: json['logDurationSeconds'] as int? ?? 420,
      );
}

final class RemoteProfilerSnapshot {
  const RemoteProfilerSnapshot({required this.path, required this.size});

  final String path;
  final int size;
}

enum RemoteProfilerPhase {
  preparing,
  staged,
  starting,
  recording,
  ready,
  complete,
  failed,
  recovered,
  operatorChanged,
}

final class RemoteProfilerCapture {
  const RemoteProfilerCapture({
    required this.id,
    required this.target,
    required this.createdAt,
    required this.originalStartup,
    required this.durationSeconds,
    required this.live,
    required this.port,
    required this.phase,
    this.stage,
    this.startupRestored = false,
    this.attached = false,
    this.error,
    this.files = const <String>[],
  });

  final String id;
  final RemoteProfilerTarget target;
  final DateTime createdAt;
  final String originalStartup;
  final int durationSeconds;
  final bool live;
  final int port;
  final RemoteProfilerPhase phase;
  final RemoteProfilerStage? stage;
  final bool startupRestored;
  final bool attached;
  final String? error;
  final List<String> files;

  bool get blocksCapture =>
      !startupRestored ||
      (phase != RemoteProfilerPhase.complete &&
          phase != RemoteProfilerPhase.recovered &&
          !(phase == RemoteProfilerPhase.failed && files.isNotEmpty));

  RemoteProfilerCapture copyWith({
    RemoteProfilerPhase? phase,
    RemoteProfilerStage? stage,
    bool? startupRestored,
    String? error,
    List<String>? files,
  }) => RemoteProfilerCapture(
    id: id,
    target: target,
    createdAt: createdAt,
    originalStartup: originalStartup,
    durationSeconds: durationSeconds,
    live: live,
    port: port,
    phase: phase ?? this.phase,
    stage: stage ?? this.stage,
    startupRestored: startupRestored ?? this.startupRestored,
    attached: attached,
    error: error,
    files: files ?? this.files,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'id': id,
    'target': target.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'originalStartup': originalStartup,
    'durationSeconds': durationSeconds,
    'live': live,
    'port': port,
    'phase': phase.name,
    'stage': stage?.toJson(),
    'startupRestored': startupRestored,
    'attached': attached,
    'error': error,
    'files': files,
  };

  factory RemoteProfilerCapture.fromJson(Map<String, Object?> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported remote capture state schema.');
    }
    return RemoteProfilerCapture(
      id: json['id'] as String,
      target: RemoteProfilerTarget.fromJson(
        Map<String, Object?>.from(json['target'] as Map),
      ),
      createdAt: DateTime.parse(json['createdAt'] as String),
      originalStartup: json['originalStartup'] as String,
      durationSeconds: json['durationSeconds'] as int,
      live: json['live'] as bool,
      port: json['port'] as int,
      phase: RemoteProfilerPhase.values.byName(json['phase'] as String),
      stage: json['stage'] == null
          ? null
          : RemoteProfilerStage.fromJson(
              Map<String, Object?>.from(json['stage'] as Map),
            ),
      startupRestored: json['startupRestored'] as bool,
      attached: json['attached'] as bool? ?? false,
      error: json['error'] as String?,
      files: (json['files'] as List).cast<String>(),
    );
  }
}

final class RemoteProfilerFetch {
  const RemoteProfilerFetch({
    required this.capture,
    required this.files,
    required this.logsPath,
  });

  final RemoteProfilerCapture capture;
  final List<String> files;
  final String logsPath;
}

abstract interface class RemoteProfilerTunnel {
  int get localPort;
  Future<int> get exitCode;
  Future<void> close();
}
