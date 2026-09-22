import 'remote_profiler_models.dart';

abstract interface class RemoteProfilerGateway {
  Future<RemoteProfilerTarget> resolveTarget(String selector);
  Future<RemoteProfilerCheck> inspect(RemoteProfilerTarget target);
  Future<RemoteProfilerStage> stage(
    RemoteProfilerTarget target,
    String captureId,
    RemoteProfilerOptions options,
  );
  Future<String> readStartup(RemoteProfilerTarget target);
  Future<void> writeStartup(RemoteProfilerTarget target, String command);
  Future<void> stopGracefully(RemoteProfilerTarget target, Duration timeout);
  Future<void> start(RemoteProfilerTarget target);
  Future<void> attach(
    RemoteProfilerTarget target,
    RemoteProfilerStage stage,
    RemoteProfilerOptions options,
  );
  Future<bool> confirmLaunch(
    RemoteProfilerTarget target,
    RemoteProfilerStage stage,
    Duration timeout,
  );
  Future<List<RemoteProfilerSnapshot>> listSnapshots(
    RemoteProfilerTarget target,
    String remoteDirectory,
  );
  Future<void> download(
    RemoteProfilerTarget target,
    String remotePath,
    String localPath,
  );
  Future<void> downloadLogs(
    RemoteProfilerTarget target,
    String remoteDirectory,
    String localPath,
  );
  Future<RemoteProfilerTunnel> openTunnel(
    RemoteProfilerTarget target,
    int remotePort,
    int localPort,
  );
}
