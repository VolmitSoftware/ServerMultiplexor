import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/native_command_service.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late NativeCommandService service;
  late String instanceDirectory;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('multiplexor-ports-');
    final ManagerContext context = ManagerContext(
      rootDir: root.path,
      verbose: false,
    );
    final ConsumerService consumers = ConsumerService(context);
    instanceDirectory = p.join(
      consumers.rootFor(ConsumerProfile.plugin),
      'instances',
      'port-test',
    );
    service = NativeCommandService(
      context: context,
      consumerService: consumers,
      javaInspector: (String _) async => 25,
      processExecutor: (String executable, List<String> arguments) async =>
          ProcessResult(
            0,
            executable == 'tmux' && arguments.first == '-V' ? 0 : 1,
            '',
            '',
          ),
    );
    final CapturedResult created = await service.execute(<String>[
      'instance',
      'create',
      'port-test',
      '--isolated',
    ], stream: false);
    expect(created.exitCode, 0, reason: created.stderr);
  });

  tearDown(() {
    service.disposeRcon();
    root.deleteSync(recursive: true);
  });

  Future<int> preparePort(int configured) async {
    final CapturedResult configuredResult = await service.execute(<String>[
      'instance',
      'port',
      'port-test',
      '$configured',
    ], stream: false);
    expect(configuredResult.exitCode, 0, reason: configuredResult.stderr);
    final CapturedResult started = await service
        .execute(<String>['runtime', 'start', 'port-test'], stream: false)
        .timeout(const Duration(seconds: 5));
    expect(started.exitCode, 2);
    expect(started.stderr, contains('No launch target found'));
    return int.parse(
      File(p.join(instanceDirectory, 'server.properties'))
          .readAsLinesSync()
          .firstWhere((String line) => line.startsWith('server-port='))
          .split('=')
          .last,
    );
  }

  test('runtime preserves an available configured port', () async {
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    final int configured = socket.port;
    await socket.close();
    expect(await preparePort(configured), configured);
  });

  for (final InternetAddress address in <InternetAddress>[
    InternetAddress.anyIPv4,
    InternetAddress.anyIPv6,
  ]) {
    test('runtime skips a port held on ${address.address}', () async {
      final ServerSocket socket;
      try {
        socket = await ServerSocket.bind(address, 0);
      } on SocketException catch (error) {
        if (address.type == InternetAddressType.IPv6 &&
            const <int>{
              47,
              49,
              97,
              99,
              10047,
              10049,
            }.contains(error.osError?.errorCode)) {
          markTestSkipped('IPv6 is unavailable');
          return;
        }
        rethrow;
      }
      addTearDown(socket.close);
      expect(await preparePort(socket.port), isNot(socket.port));
    });
  }

  for (final int errorCode in <int>[48, 10048]) {
    test(
      'runtime rejects address-in-use error $errorCode during fallback',
      () async {
        final int assigned = await IOOverrides.runWithIOOverrides(
          () => preparePort(25565),
          _PortBindOverrides(blockedPort: 25565, blockedErrorCode: errorCode),
        );
        expect(assigned, isNot(25565));
      },
    );
  }

  for (final int errorCode in <int>[47, 49, 10047, 10049]) {
    test('runtime keeps IPv4 usable after IPv6 error $errorCode', () async {
      final ServerSocket socket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      final int configured = socket.port;
      await socket.close();
      final int assigned = await IOOverrides.runWithIOOverrides(
        () => preparePort(configured),
        _PortBindOverrides(ipv6ErrorCode: errorCode),
      );
      expect(assigned, configured);
    });
  }
}

final class _PortBindOverrides extends IOOverrides {
  _PortBindOverrides({
    this.blockedPort,
    this.blockedErrorCode,
    this.ipv6ErrorCode,
  });

  final int? blockedPort;
  final int? blockedErrorCode;
  final int? ipv6ErrorCode;

  @override
  Future<ServerSocket> serverSocketBind(
    dynamic address,
    int port, {
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
  }) {
    if (port == blockedPort) {
      throw SocketException(
        'Failed to create server socket',
        osError: OSError('Socket address is occupied', blockedErrorCode!),
      );
    }
    if (ipv6ErrorCode != null &&
        address is InternetAddress &&
        address.type == InternetAddressType.IPv6) {
      throw SocketException(
        'Failed to create server socket',
        osError: OSError('IPv6 unavailable', ipv6ErrorCode!),
      );
    }
    return super.serverSocketBind(
      address,
      port,
      backlog: backlog,
      v6Only: v6Only,
      shared: shared,
    );
  }
}
