import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../pterodactyl/pterodactyl_models.dart';
import '../pterodactyl/pterodactyl_profile.dart';
import '../pterodactyl/pterodactyl_service.dart';
import '../pterodactyl/pterodactyl_smb_process.dart';
import 'remote_profiler_gateway.dart';
import 'remote_profiler_host_store.dart';
import 'remote_profiler_models.dart';

typedef RemoteProfilerDownload =
    Future<void> Function(List<String> sshArguments, String localPath);

final class SshRemoteProfilerGateway implements RemoteProfilerGateway {
  SshRemoteProfilerGateway({
    required this.pterodactyl,
    required String profileId,
    required this.hosts,
    PterodactylSmbProcessRunner? processRunner,
    RemoteProfilerDownload? downloader,
  }) : profileId = PterodactylProfile.normalizeId(profileId),
       _runner = processRunner ?? const DartIoPterodactylSmbProcessRunner(),
       _downloader = downloader ?? _downloadTar;

  final PterodactylService pterodactyl;
  final String profileId;
  final RemoteProfilerHostStore hosts;
  final PterodactylSmbProcessRunner _runner;
  final RemoteProfilerDownload _downloader;

  Future<void> configureHost(
    String selector,
    String sshTarget, {
    int sshPort = 22,
    String? identityFile,
    String? knownHostsFile,
    bool sudoDocker = false,
  }) async {
    final RemoteProfilerTarget target = await resolveTarget(selector);
    hosts.save(
      RemoteProfilerHostConfig(
        profileId: profileId,
        nodeId: target.nodeId,
        sshTarget: sshTarget,
        sshPort: sshPort,
        identityFile: identityFile,
        knownHostsFile: knownHostsFile,
        sudoDocker: sudoDocker,
      ),
    );
  }

  @override
  Future<RemoteProfilerTarget> resolveTarget(String selector) async {
    final PterodactylApplicationServer server = await pterodactyl
        .applicationServer(profileId, selector);
    return RemoteProfilerTarget(
      id: server.identifier,
      uuid: server.uuid,
      name: server.name,
      profileId: profileId,
      nodeId: server.nodeId,
    );
  }

  @override
  Future<RemoteProfilerCheck> inspect(RemoteProfilerTarget target) async {
    final String startup = await readStartup(target);
    final _Container container = await _container(target);
    final PterodactylSmbCommandResult probe = await _probe(
      target,
      container,
      r'uname -s; uname -m; id -u; id -g; java -version 2>&1; ldd --version 2>&1',
    );
    final List<String> lines = const LineSplitter().convert(probe.stdout);
    final List<String> issues = <String>[];
    if (lines.length < 5) {
      throw StateError('Could not inspect the server Java runtime.');
    }
    if (lines[0] != 'Linux') {
      issues.add('Remote JProfiler requires a Linux container.');
    }
    if (!<String>['x86_64', 'aarch64'].contains(lines[1])) {
      issues.add('Unsupported container architecture: ${lines[1]}.');
    }
    if (probe.stdout.toLowerCase().contains('musl')) {
      issues.add(
        'The selected JProfiler agent requires glibc; this image uses musl.',
      );
    }
    final String java = lines
        .skip(4)
        .firstWhere(
          (String line) => RegExp(r'(?:openjdk|java) version ').hasMatch(line),
          orElse: () => '',
        );
    if (java.isEmpty) {
      issues.add('The container does not expose a Java runtime.');
    }
    return RemoteProfilerCheck(
      target: target,
      javaVersion: java,
      os: lines[0],
      architecture: lines[1],
      startupCommand: startup,
      isRunning: container.running,
      issues: issues,
    );
  }

  static final RegExp _javaLaunch = RegExp(
    r'^(\s*(?:exec\s+)?(?:java|/[^\s\x27\x22]+/java))(?=\s|$)',
  );

  @override
  Future<RemoteProfilerStage> stage(
    RemoteProfilerTarget target,
    String captureId,
    RemoteProfilerOptions options,
  ) async {
    options.validate();
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(captureId)) {
      throw ArgumentError('Invalid capture ID.');
    }
    final _Container container = await _container(target);
    final PterodactylSmbCommandResult probe = await _probe(
      target,
      container,
      'uname -m; id -u; id -g',
    );
    final List<String> values = const LineSplitter().convert(probe.stdout);
    if (values.length != 3) {
      throw StateError('Could not inspect container identity.');
    }
    final int uid = int.parse(values[1]);
    final int gid = int.parse(values[2]);
    final Directory agentDirectory = Directory(options.agentDirectory);
    if (!agentDirectory.existsSync()) {
      throw ArgumentError('The JProfiler agent directory does not exist.');
    }
    final String architecture = switch (values[0]) {
      'x86_64' => 'linux-x64',
      'aarch64' => 'linux-arm64',
      _ => throw StateError('Unsupported Linux architecture.'),
    };
    final List<File> agents = agentDirectory
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where(
          (File file) =>
              p.basename(file.path) == 'libjprofilerti.so' &&
              p.split(file.path).contains(architecture),
        )
        .toList();
    if (agents.length != 1) {
      throw StateError(
        'The agent directory must contain one $architecture/libjprofilerti.so.',
      );
    }
    final String relativeDirectory = '.multiplexor-profiler/$captureId';
    final String remoteDirectory = '/home/container/$relativeDirectory';
    final String snapshot = '$remoteDirectory/capture.jps';
    final Archive archive = Archive();
    for (final String directory in <String>[
      '.multiplexor-profiler',
      relativeDirectory,
      '$relativeDirectory/agent',
    ]) {
      archive.addFile(
        ArchiveFile.directory(directory)
          ..mode = 448
          ..ownerId = uid
          ..groupId = gid,
      );
    }
    for (final FileSystemEntity entry in agentDirectory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final String relative = p.posix.join(
        '$relativeDirectory/agent',
        p
            .relative(entry.path, from: agentDirectory.path)
            .split(p.separator)
            .join('/'),
      );
      if (entry is Link) {
        throw StateError('Agent bundles must not contain symbolic links.');
      }
      if (entry is Directory) {
        archive.addFile(
          ArchiveFile.directory(relative)
            ..mode = 448
            ..ownerId = uid
            ..groupId = gid,
        );
      } else if (entry is File) {
        archive.addFile(
          ArchiveFile(relative, entry.lengthSync(), entry.readAsBytesSync())
            ..mode = 448
            ..ownerId = uid
            ..groupId = gid,
        );
      }
    }
    String config = '';
    if (options.configPath != null) {
      final File file = File(options.configPath!);
      archive.addFile(
        ArchiveFile(
            '$relativeDirectory/config.xml',
            file.lengthSync(),
            file.readAsBytesSync(),
          )
          ..mode = 384
          ..ownerId = uid
          ..groupId = gid,
      );
      config = ',id=${options.sessionId},config=$remoteDirectory/config.xml';
    }
    final String agentRelative = p
        .relative(agents.single.path, from: agentDirectory.path)
        .split(p.separator)
        .join('/');
    if (!RegExp(r'^[a-zA-Z0-9_./-]+$').hasMatch(agentRelative)) {
      throw StateError(
        'Agent library paths must contain only letters, numbers, slashes, dots, hyphens, or underscores.',
      );
    }
    final String agent = '$remoteDirectory/agent/$agentRelative';
    final String argument = options.live
        ? '-agentpath:$agent=port=${options.port},address=0.0.0.0,nowait$config'
        : '-agentpath:$agent=offline,snapshot=$snapshot,recording=cpu,duration=${options.duration.inSeconds}s,callTreeMode=sampling$config';
    final String original = await readStartup(target);
    if (!options.attach &&
        (!_javaLaunch.hasMatch(original) ||
            original.contains('-agentpath:') ||
            original.contains('-agentlib:'))) {
      throw StateError('Startup is not a supported unprofiled Java launch.');
    }
    if (options.live) _requirePrivatePort(container, options.port);
    final String startup = options.attach
        ? original
        : original.replaceFirstMapped(
            _javaLaunch,
            (Match match) => '${match[1]} ${_quote(argument)}',
          );
    final RemoteProfilerHostConfig host = _host(target);
    await _checked(
      host,
      'base64 -d | ${_docker(host, <String>['cp', '-a', '-', '${container.id}:/home/container'])}',
      stdinText: base64Encode(TarEncoder().encode(archive)),
    );
    return RemoteProfilerStage(
      startupCommand: startup,
      remoteDirectory: remoteDirectory,
      snapshotPath: snapshot,
      agentArgument: argument,
      logDurationSeconds: options.live
          ? 86700
          : options.duration.inSeconds + 300,
    );
  }

  @override
  Future<void> attach(
    RemoteProfilerTarget target,
    RemoteProfilerStage stage,
    RemoteProfilerOptions options,
  ) async {
    final _Container container = await _container(target);
    if (!container.running) {
      throw StateError('Attach requires a running server.');
    }
    if (options.live) _requirePrivatePort(container, options.port);
    final RemoteProfilerHostConfig host = _host(target);
    final PterodactylSmbCommandResult discovery = await _checked(
      host,
      _docker(host, <String>[
        'exec',
        container.id,
        'sh',
        '-c',
        r'for process in /proc/[0-9]*; do exe=$(readlink "$process/exe" 2>/dev/null) || continue; case "$exe" in */java) printf "%s\n" "${process##*/}";; esac; done',
      ]),
    );
    final List<String> pids = const LineSplitter()
        .convert(discovery.stdout)
        .where((String value) => RegExp(r'^[1-9][0-9]*$').hasMatch(value))
        .toList();
    if (pids.length != 1) {
      throw StateError(
        'Attach requires exactly one Java process in the target container.',
      );
    }
    _requireCapturePath(stage.remoteDirectory);
    final int separator = stage.agentArgument.indexOf('=');
    if (!stage.agentArgument.startsWith('-agentpath:') || separator < 12) {
      throw StateError('Invalid staged profiler agent argument.');
    }
    final String library = stage.agentArgument.substring(
      '-agentpath:'.length,
      separator,
    );
    final String settings = stage.agentArgument.substring(separator + 1);
    if (!library.startsWith('${stage.remoteDirectory}/agent/') ||
        !RegExp(r'^[a-zA-Z0-9_./-]+$').hasMatch(library) ||
        library.split('/').contains('..')) {
      throw StateError('The profiler library must belong to this capture.');
    }
    final String script =
        'command -v jcmd >/dev/null || { printf %s ${_quote('Attach requires jcmd in the server image; use a full JDK image.')} >&2; exit 127; }; '
        'command -v grep >/dev/null || exit 127; '
        'test -r /proc/${pids.single}/maps || { printf %s ${_quote('Cannot inspect target JVM native libraries.')} >&2; exit 1; }; '
        'if grep -F libjprofilerti.so /proc/${pids.single}/maps >/dev/null; then printf %s ${_quote('JProfiler is already loaded in this JVM; restart normally before another attachment.')} >&2; exit 1; fi; '
        'exec jcmd ${pids.single} JVMTI.agent_load ${_quote(library)} ${_quote('"$settings"')}';
    final PterodactylSmbCommandResult result = await _checked(
      host,
      _docker(host, <String>['exec', container.id, 'sh', '-c', script]),
    );
    if (!RegExp(
      r'^return code:\s*0\s*$',
      multiLine: true,
    ).hasMatch(result.stdout)) {
      throw StateError(
        'The JVM did not confirm loading JProfiler: ${result.diagnostic}',
      );
    }
  }

  @override
  Future<String> readStartup(RemoteProfilerTarget target) async =>
      (await pterodactyl.applicationServer(
        target.profileId,
        target.id,
      )).startup;

  @override
  Future<void> writeStartup(RemoteProfilerTarget target, String command) async {
    await pterodactyl.updateStartupCommand(
      profileId: target.profileId,
      server: target.id,
      startup: command,
    );
  }

  @override
  Future<void> stopGracefully(
    RemoteProfilerTarget target,
    Duration timeout,
  ) async {
    await pterodactyl.requestGracefulStop(target.profileId, target.id);
    final Stopwatch watch = Stopwatch()..start();
    do {
      if ((await pterodactyl.resources(
            target.profileId,
            target.id,
          )).currentState ==
          'offline') {
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    } while (watch.elapsed < timeout);
    throw TimeoutException(
      'Server did not stop gracefully; it was not killed.',
      timeout,
    );
  }

  @override
  Future<void> start(RemoteProfilerTarget target) => pterodactyl.power(
    target.profileId,
    target.id,
    PterodactylPowerSignal.start,
  );

  @override
  Future<bool> confirmLaunch(
    RemoteProfilerTarget target,
    RemoteProfilerStage stage,
    Duration timeout,
  ) async {
    final Stopwatch watch = Stopwatch()..start();
    final String agent = stage.agentArgument
        .substring('-agentpath:'.length)
        .split('=')
        .first;
    do {
      try {
        final _Container container = await _container(target);
        if (container.running) {
          await _startLogCapture(target, container, stage);
          final RemoteProfilerHostConfig host = _host(target);
          final PterodactylSmbCommandResult result = await _run(
            host,
            _docker(host, <String>[
              'exec',
              container.id,
              'sh',
              '-c',
              'command -v grep >/dev/null || exit 4; for maps in /proc/[0-9]*/maps; do if grep -F -- ${_quote(agent)} "\$maps" >/dev/null 2>&1; then exit 0; fi; done; exit 3',
            ]),
          );
          if (result.exitCode == 0) return true;
          if (result.exitCode != 3 &&
              !_containerTransition(result, container.id)) {
            throw StateError(
              'Could not confirm profiler startup: ${result.diagnostic}',
            );
          }
        }
      } on _ContainerUnavailable {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    } while (watch.elapsed < timeout);
    return false;
  }

  Future<void> _startLogCapture(
    RemoteProfilerTarget target,
    _Container container,
    RemoteProfilerStage stage,
  ) async {
    _requireCapturePath(stage.remoteDirectory);
    if (stage.logDurationSeconds < 1 || stage.logDurationSeconds > 86700) {
      throw StateError('Invalid capture log collection duration.');
    }
    final RemoteProfilerHostConfig host = _host(target);
    final String marker = '${stage.remoteDirectory}/.log-collector';
    final PterodactylSmbCommandResult claim = await _run(
      host,
      _docker(host, <String>[
        'exec',
        container.id,
        'sh',
        '-c',
        'if mkdir ${_quote(marker)} 2>/dev/null; then printf started; elif test -d ${_quote(marker)}; then printf existing; else exit 1; fi',
      ]),
    );
    if (claim.exitCode != 0) {
      if (_containerTransition(claim, container.id)) {
        throw _ContainerUnavailable(claim.diagnostic);
      }
      throw StateError(
        'Could not start capture log collection: ${claim.diagnostic}',
      );
    }
    if (claim.stdout == 'existing') return;
    if (claim.stdout != 'started') {
      throw StateError('Unexpected capture log collector response.');
    }
    final String writer = _docker(host, <String>[
      'exec',
      '-i',
      container.id,
      'sh',
      '-c',
      'umask 077; cat > ${_quote('${stage.remoteDirectory}/startup.log')}',
    ]);
    final String reader = _docker(host, <String>[
      'logs',
      '--follow',
      '--timestamps',
      container.id,
    ]);
    final String pipeline = '$reader 2>&1 | $writer';
    await _checked(
      host,
      'command -v nohup >/dev/null && command -v timeout >/dev/null || exit 1; nohup timeout --kill-after=5s ${stage.logDurationSeconds}s sh -c ${_quote(pipeline)} >/dev/null 2>&1 </dev/null &',
    );
  }

  @override
  Future<List<RemoteProfilerSnapshot>> listSnapshots(
    RemoteProfilerTarget target,
    String remoteDirectory,
  ) async {
    _requireCapturePath(remoteDirectory);
    final _Container container = await _container(target);
    final RemoteProfilerHostConfig host = _host(target);
    final String hostDirectory =
        '${container.storage}/${remoteDirectory.substring('/home/container/'.length)}';
    final PterodactylSmbCommandResult result = await _checked(
      host,
      '${host.sudoDocker ? 'sudo -n ' : ''}find ${_quote(hostDirectory)} -maxdepth 1 -type f -name ${_quote('*.jps')} -printf ${_quote('%f\t%s\n')}',
    );
    final Set<String> openPaths = <String>{};
    if (container.running) {
      final PterodactylSmbCommandResult open = await _checked(
        host,
        _docker(host, <String>[
          'exec',
          '--user',
          '0',
          container.id,
          'sh',
          '-c',
          r'command -v readlink >/dev/null || exit 1; for fd in /proc/[0-9]*/fd/*; do readlink "$fd" 2>/dev/null || true; done',
        ]),
      );
      openPaths.addAll(const LineSplitter().convert(open.stdout));
    }
    final Set<String> completed = await _completedSnapshots(
      host,
      container,
      remoteDirectory,
    );
    return const LineSplitter()
        .convert(result.stdout)
        .where((String line) => line.isNotEmpty)
        .map((String line) {
          final List<String> parts = line.split('\t');
          if (parts.length != 2 ||
              !RegExp(r'^[a-zA-Z0-9_.-]+\.jps$').hasMatch(parts[0])) {
            throw StateError('Invalid remote snapshot metadata.');
          }
          return RemoteProfilerSnapshot(
            path: '$remoteDirectory/${parts[0]}',
            size: int.parse(parts[1]),
          );
        })
        .where(
          (RemoteProfilerSnapshot file) =>
              !openPaths.contains(file.path) && completed.contains(file.path),
        )
        .toList();
  }

  Future<Set<String>> _completedSnapshots(
    RemoteProfilerHostConfig host,
    _Container container,
    String remoteDirectory,
  ) async {
    final String copy = _docker(host, <String>[
      'cp',
      '${container.id}:$remoteDirectory/startup.log',
      '-',
    ]);
    final PterodactylSmbCommandResult result = await _run(
      host,
      'bash -o pipefail -c ${_quote('$copy | tar -xOf - | sed -n ${_quote('/JProfiler>/p')}')}',
    );
    if (result.exitCode != 0) {
      if (result.stderr.contains('Could not find the file') ||
          result.stderr.contains('no such file or directory')) {
        return <String>{};
      }
      throw StateError(
        'Could not read capture completion log: ${result.diagnostic}',
      );
    }
    final Set<String> completed = <String>{};
    String? pending;
    for (final String line in const LineSplitter().convert(result.stdout)) {
      final int start = line.indexOf('JProfiler> Saving snapshot ');
      if (start >= 0 && line.endsWith(' ...')) {
        pending = line.substring(
          start + 'JProfiler> Saving snapshot '.length,
          line.length - 4,
        );
        completed.remove(pending);
      } else if (line.endsWith('JProfiler> Done.') && pending != null) {
        completed.add(pending);
        pending = null;
      }
    }
    return completed;
  }

  @override
  Future<void> download(
    RemoteProfilerTarget target,
    String remotePath,
    String localPath,
  ) async {
    _requireCapturePath(remotePath);
    await _download(target, remotePath, localPath);
  }

  @override
  Future<void> downloadLogs(
    RemoteProfilerTarget target,
    String remoteDirectory,
    String localPath,
  ) async {
    _requireCapturePath(remoteDirectory);
    await _download(target, '$remoteDirectory/startup.log', localPath);
  }

  Future<void> _download(
    RemoteProfilerTarget target,
    String remotePath,
    String localPath,
  ) async {
    final _Container container = await _container(target);
    final RemoteProfilerHostConfig host = _host(target);
    await _downloader(<String>[
      ...sshArguments(host),
      _docker(host, <String>['cp', '${container.id}:$remotePath', '-']),
    ], localPath);
  }

  @override
  Future<RemoteProfilerTunnel> openTunnel(
    RemoteProfilerTarget target,
    int remotePort,
    int localPort,
  ) async {
    if (remotePort < 1 ||
        remotePort > 65535 ||
        localPort < 1 ||
        localPort > 65535) {
      throw ArgumentError('Invalid tunnel port.');
    }
    final _Container container = await _container(target);
    if (!container.running || container.address.isEmpty) {
      throw StateError(
        'The target container must be running on a private Docker network.',
      );
    }
    _requirePrivatePort(container, remotePort);
    final RemoteProfilerHostConfig host = _host(target);
    await _checked(
      host,
      'timeout 5 bash -c ${_quote('exec 3<>/dev/tcp/${container.address}/$remotePort')}',
    );
    final List<String> arguments = sshArguments(host);
    final String destination = arguments.removeLast();
    arguments.addAll(<String>[
      '-o',
      'ExitOnForwardFailure=yes',
      '-N',
      '-L',
      '127.0.0.1:$localPort:${container.address}:$remotePort',
      destination,
    ]);
    final PterodactylSmbProcessHandle process = await _runner.start(
      'ssh',
      arguments,
    );
    if (await process.waitForExit(const Duration(milliseconds: 400)) != null) {
      throw StateError('Could not open profiler tunnel: ${process.diagnostic}');
    }
    return _SshTunnel(localPort, process);
  }

  RemoteProfilerHostConfig _host(RemoteProfilerTarget target) =>
      hosts.load(target.profileId, target.nodeId) ??
      (throw StateError(
        'Configure an SSH host for this Panel node with remote profile host-set.',
      ));

  Future<_Container> _container(RemoteProfilerTarget target) async {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(target.uuid)) {
      throw StateError('The Panel did not return a full server UUID.');
    }
    final RemoteProfilerHostConfig host = _host(target);
    final PterodactylSmbCommandResult result = await _run(
      host,
      _docker(host, <String>['inspect', '--type', 'container', target.uuid]),
    );
    if (result.exitCode != 0) {
      if (_containerTransition(result, target.uuid)) {
        throw _ContainerUnavailable(result.diagnostic);
      }
      throw StateError(
        'Remote profiler container inspection failed: ${result.diagnostic}',
      );
    }
    final Object? data = jsonDecode(result.stdout);
    if (data is! List<Object?> ||
        data.length != 1 ||
        data.single is! Map<String, Object?>) {
      throw StateError('Unexpected Docker container metadata.');
    }
    final Map<String, Object?> json = data.single as Map<String, Object?>;
    if (json['Name'] != '/${target.uuid}') {
      throw StateError(
        'Docker container identity does not match the Panel server UUID.',
      );
    }
    final Map<String, Object?> config = json['Config'] as Map<String, Object?>;
    final Map<String, Object?> state = json['State'] as Map<String, Object?>;
    final List<Object?> mounts = json['Mounts'] as List<Object?>;
    final List<Map<String, Object?>> storage = mounts
        .cast<Map<String, Object?>>()
        .where(
          (Map<String, Object?> mount) =>
              mount['Destination'] == '/home/container' && mount['RW'] == true,
        )
        .toList();
    if (storage.length != 1) {
      throw StateError(
        'The container has no unique writable persistent /home/container mount.',
      );
    }
    final Map<String, Object?> network =
        json['NetworkSettings'] as Map<String, Object?>;
    final Map<String, Object?> hostConfig =
        json['HostConfig'] as Map<String, Object?>? ?? <String, Object?>{};
    final Map<String, Object?> ports =
        network['Ports'] as Map<String, Object?>? ?? <String, Object?>{};
    final Map<String, Object?> configuredPorts =
        hostConfig['PortBindings'] as Map<String, Object?>? ??
        <String, Object?>{};
    ports.addAll(configuredPorts);
    final Map<String, Object?> networks =
        network['Networks'] as Map<String, Object?>;
    final List<String> addresses = networks.values
        .cast<Map<String, Object?>>()
        .map((Map<String, Object?> item) => item['IPAddress'] as String? ?? '')
        .where((String value) => value.isNotEmpty)
        .toList();
    final String address = addresses.firstOrNull ?? '';
    if (address.isNotEmpty &&
        InternetAddress.tryParse(address)?.type != InternetAddressType.IPv4) {
      throw StateError('Invalid Docker network address.');
    }
    return _Container(
      id: json['Id'] as String,
      image: json['Image'] as String,
      user: config['User'] as String? ?? '',
      running: state['Running'] == true,
      storage: storage.single['Source'] as String,
      address: address,
      hostNetwork: hostConfig['NetworkMode'] == 'host',
      publishedPorts: ports.entries
          .where((MapEntry<String, Object?> entry) => entry.value != null)
          .map((MapEntry<String, Object?> entry) => entry.key)
          .toSet(),
    );
  }

  Future<PterodactylSmbCommandResult> _probe(
    RemoteProfilerTarget target,
    _Container container,
    String script,
  ) {
    final RemoteProfilerHostConfig host = _host(target);
    return _checked(
      host,
      _docker(
        host,
        container.running
            ? <String>['exec', container.id, 'sh', '-c', script]
            : <String>[
                'run',
                '--rm',
                '--pull=never',
                if (container.user.isNotEmpty) ...<String>[
                  '--user',
                  container.user,
                ],
                '--network',
                'none',
                '--read-only',
                '--entrypoint',
                'sh',
                container.image,
                '-c',
                script,
              ],
      ),
    );
  }

  static List<String> sshArguments(RemoteProfilerHostConfig host) => <String>[
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    '-o',
    'ConnectTimeout=15',
    '-o',
    'ServerAliveInterval=15',
    '-o',
    'ServerAliveCountMax=3',
    '-p',
    '${host.sshPort}',
    if (host.identityFile != null) ...<String>[
      '-i',
      host.identityFile!,
      '-o',
      'IdentitiesOnly=yes',
    ],
    if (host.knownHostsFile != null) ...<String>[
      '-o',
      'UserKnownHostsFile=${host.knownHostsFile}',
    ],
    host.sshTarget,
  ];

  Future<PterodactylSmbCommandResult> _run(
    RemoteProfilerHostConfig host,
    String command, {
    String? stdinText,
  }) => _runner.run('ssh', <String>[
    ...sshArguments(host),
    command,
  ], stdinText: stdinText);

  Future<PterodactylSmbCommandResult> _checked(
    RemoteProfilerHostConfig host,
    String command, {
    String? stdinText,
  }) async {
    final PterodactylSmbCommandResult result = await _run(
      host,
      command,
      stdinText: stdinText,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Remote profiler host command failed: ${result.diagnostic}',
      );
    }
    return result;
  }

  static String _docker(
    RemoteProfilerHostConfig host,
    List<String> arguments,
  ) =>
      '${host.sudoDocker ? 'sudo -n ' : ''}docker ${arguments.map(_quote).join(' ')}';
  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static void _requireCapturePath(String value) {
    if (!RegExp(
          r'^/home/container/\.multiplexor-profiler/[a-zA-Z0-9_-]+(?:/[a-zA-Z0-9_.-]+)?$',
        ).hasMatch(value) ||
        value.split('/').contains('..')) {
      throw ArgumentError('Invalid profiler capture path.');
    }
  }

  static bool _containerTransition(
    PterodactylSmbCommandResult result,
    String identity,
  ) {
    final String message = result.stderr.toLowerCase();
    return message.contains('no such container: $identity') ||
        message.contains('no such object: $identity') ||
        message.contains('container $identity is not running');
  }

  static void _requirePrivatePort(_Container container, int port) {
    if (container.hostNetwork ||
        container.publishedPorts.contains('$port/tcp')) {
      throw StateError(
        'Live profiling requires private container networking and an unpublished profiler port.',
      );
    }
  }

  static Future<void> _downloadTar(
    List<String> arguments,
    String localPath,
  ) async {
    final File destination = File(localPath);
    await destination.parent.create(recursive: true);
    final Directory temporary = await Directory.systemTemp.createTemp(
      'multiplexor-profile-',
    );
    try {
      final File tar = File(p.join(temporary.path, 'snapshot.tar'));
      final Process process = await Process.start(
        'ssh',
        arguments,
        runInShell: false,
      );
      await process.stdin.close();
      final Future<String> errors = process.stderr
          .transform(utf8.decoder)
          .join();
      await process.stdout.pipe(tar.openWrite());
      final int code = await process.exitCode;
      final String diagnostic = await errors;
      if (code != 0) {
        throw StateError('Remote snapshot download failed: $diagnostic');
      }
      final InputFileStream input = InputFileStream(tar.path);
      try {
        final Archive archive = TarDecoder().decodeStream(input);
        final List<ArchiveFile> files = archive.files
            .where((ArchiveFile file) => file.isFile)
            .toList();
        if (files.length != 1) {
          throw StateError('Expected exactly one file in the remote download.');
        }
        final File pending = File('${destination.path}.tmp-$pid');
        try {
          final OutputFileStream output = OutputFileStream(pending.path);
          try {
            files.single.writeContent(output);
          } finally {
            output.closeSync();
          }
          await pending.rename(destination.path);
        } finally {
          if (pending.existsSync()) pending.deleteSync();
        }
      } finally {
        input.closeSync();
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

final class _Container {
  const _Container({
    required this.id,
    required this.image,
    required this.user,
    required this.running,
    required this.storage,
    required this.address,
    required this.hostNetwork,
    required this.publishedPorts,
  });
  final String id;
  final String image;
  final String user;
  final bool running;
  final String storage;
  final String address;
  final bool hostNetwork;
  final Set<String> publishedPorts;
}

final class _SshTunnel implements RemoteProfilerTunnel {
  _SshTunnel(this.localPort, this.process);
  @override
  final int localPort;
  final PterodactylSmbProcessHandle process;
  late final Future<int> _exitCode = _waitForExit();
  @override
  Future<int> get exitCode => _exitCode;
  Future<int> _waitForExit() async {
    while (true) {
      final int? result = await process.waitForExit(const Duration(seconds: 1));
      if (result != null) return result;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  bool _closed = false;
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    process.kill();
    if (await process.waitForExit(const Duration(seconds: 5)) == null) {
      process.kill(ProcessSignal.sigkill);
    }
  }
}

final class _ContainerUnavailable implements Exception {
  const _ContainerUnavailable(this.message);
  final String message;
  @override
  String toString() => 'Remote server container is unavailable: $message';
}
