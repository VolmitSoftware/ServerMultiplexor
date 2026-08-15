import 'dart:io';

import 'package:multiplexor/models/consumer_profile.dart';
import 'package:multiplexor/services/consumer_service.dart';
import 'package:multiplexor/services/manager_context.dart';
import 'package:multiplexor/services/passthrough_service.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_native_local_instance_gateway.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_files.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_transfer_models.dart';
import 'package:multiplexor/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late ConsumerProfile selectedConsumer;
  late ConsumerService consumers;
  late PterodactylNativeLocalInstanceGateway gateway;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync(
      'multiplexor-transfer-local-',
    );
    final ManagerContext context = ManagerContext(
      rootDir: temporary.path,
      verbose: false,
    );
    consumers = ConsumerService(context);
    selectedConsumer = ConsumerProfile.plugin;
    gateway = PterodactylNativeLocalInstanceGateway(
      passthrough: PassthroughService(context, consumers),
      loadConsumer: () => selectedConsumer,
    );
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test(
    'creates, resolves, and deletes through the native instance engine',
    () async {
      final PterodactylLocalInstance created = await gateway.createStopped(
        'pulled-server',
      );

      expect(created.name, 'pulled-server');
      expect(created.consumer, 'plugin');
      expect(Directory(created.path).existsSync(), isTrue);
      expect(
        File('${created.path}/.server-source').readAsStringSync(),
        contains('isolated=true'),
      );
      expect(
        FileSystemEntity.typeSync(
          '${created.path}/ops.json',
          followLinks: false,
        ),
        isNot(FileSystemEntityType.link),
      );
      expect(
        FileSystemEntity.typeSync(
          '${created.path}/plugins/iris/packs',
          followLinks: false,
        ),
        isNot(FileSystemEntityType.link),
      );
      expect(await gateway.isRunning(created), isFalse);
      expect((await gateway.resolve('pulled-server')).path, created.path);

      await gateway.delete(created);
      expect(Directory(created.path).existsSync(), isFalse);
      await expectLater(gateway.resolve('pulled-server'), throwsStateError);
    },
  );

  test('loads the selected consumer for each new operation', () async {
    final PterodactylLocalInstance plugin = await gateway.createStopped(
      'plugin-copy',
    );
    selectedConsumer = ConsumerProfile.fabric;
    final PterodactylLocalInstance fabric = await gateway.createStopped(
      'fabric-copy',
    );

    expect(plugin.consumer, 'plugin');
    expect(plugin.path, contains('plugin-consumers'));
    expect(fabric.consumer, 'fabric');
    expect(fabric.path, contains('fabric-mod-consumers'));
  });

  test('allows launch jars only through a managed content root', () async {
    if (Platform.isWindows) return;
    final PterodactylLocalInstance created = await gateway.createStopped(
      'managed-jar',
    );
    final File jar = File(
      '${consumers.rootFor(ConsumerProfile.plugin)}/builds/custom/test.jar',
    );
    jar.parent.createSync(recursive: true);
    jar.writeAsStringSync('jar');
    Link('${created.path}/server.jar').createSync(jar.path);
    File('${created.path}/.server-source').writeAsStringSync(
      'type=custom\nlaunch=jar\njar=${jar.path}\nisolated=true\n',
    );

    final PterodactylLocalInstance resolved = await gateway.resolve(
      'managed-jar',
    );
    final PterodactylTransferFileManifest manifest =
        await const PterodactylTransferFileEngine().scan(
          resolved.path,
          exclude: (String path) => path == '.server-source',
          allowSymlinks: true,
          allowedSymlinkRoots: resolved.safeSymlinkRoots,
        );
    expect(manifest.files['server.jar']!.sha256, isNotEmpty);
  });

  test(
    'rejects legacy external launch links with migration guidance',
    () async {
      if (Platform.isWindows) return;
      final PterodactylLocalInstance created = await gateway.createStopped(
        'legacy-external',
      );
      final File jar = File('${temporary.path}/external/custom.jar');
      jar.parent.createSync(recursive: true);
      jar.writeAsStringSync('jar');
      Link('${created.path}/server.jar').createSync(jar.path);
      File('${created.path}/.server-source').writeAsStringSync(
        'type=custom\nlaunch=jar\njar=${jar.path}\nisolated=true\n',
      );

      await expectLater(
        gateway.resolve('legacy-external'),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('instance update legacy-external --jar <path>'),
          ),
        ),
      );
    },
  );

  test('rejects an instance entry symlink that escapes its store', () async {
    if (Platform.isWindows) return;
    consumers.ensureConsumerDirs(ConsumerProfile.plugin);
    final Directory outside = Directory('${temporary.path}/outside-secret')
      ..createSync();
    File('${outside.path}/id_ed25519').writeAsStringSync('secret');
    Link(
      '${consumers.rootFor(ConsumerProfile.plugin)}/instances/escaped',
    ).createSync(outside.path);

    await expectLater(gateway.resolve('escaped'), throwsStateError);
  });

  test('rejects managed content roots replaced by symlinks', () async {
    if (Platform.isWindows) return;
    final PterodactylLocalInstance created = await gateway.createStopped(
      'unsafe-build-root',
    );
    final Directory builds = Directory(
      '${consumers.rootFor(ConsumerProfile.plugin)}/builds',
    );
    builds.deleteSync();
    final Directory outside = Directory('${temporary.path}/outside-builds')
      ..createSync();
    Link(builds.path).createSync(outside.path);

    await expectLater(gateway.resolve(created.name), throwsStateError);
  });

  test('preserves a pre-existing non-directory instance entity', () async {
    consumers.ensureConsumerDirs(ConsumerProfile.plugin);
    final File existing = File(
      '${consumers.rootFor(ConsumerProfile.plugin)}/instances/preexisting',
    )..writeAsStringSync('keep me');

    await expectLater(gateway.createStopped('preexisting'), throwsStateError);

    expect(existing.readAsStringSync(), 'keep me');
  });

  test('attempts owned partial cleanup when native creation fails', () async {
    final ManagerContext context = ManagerContext(
      rootDir: temporary.path,
      verbose: false,
    );
    final _PartialCreatePassthrough passthrough = _PartialCreatePassthrough(
      context,
      consumers,
    );
    final PterodactylNativeLocalInstanceGateway partialGateway =
        PterodactylNativeLocalInstanceGateway(
          passthrough: passthrough,
          loadConsumer: () => ConsumerProfile.plugin,
        );

    await expectLater(
      partialGateway.createStopped('partial'),
      throwsStateError,
    );

    expect(passthrough.cleanupCalled, isTrue);
    expect(
      FileSystemEntity.typeSync(
        '${consumers.rootFor(ConsumerProfile.plugin)}/instances/partial',
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
  });
}

final class _PartialCreatePassthrough extends PassthroughService {
  _PartialCreatePassthrough(super.context, super.consumerService);

  String? _creationToken;
  String? _createdPath;
  bool cleanupCalled = false;

  @override
  Future<CapturedResult> createIsolatedTransferInstance(
    String name, {
    required String creationToken,
  }) async {
    _creationToken = creationToken;
    _createdPath = p.join(
      consumerService.rootFor(effectiveConsumer),
      'instances',
      name,
    );
    Directory(_createdPath!).createSync(recursive: true);
    return CapturedResult(
      exitCode: 1,
      stdout: '',
      stderr: 'simulated partial native failure',
    );
  }

  @override
  bool cleanupPartialTransferInstance(
    String name, {
    required String creationToken,
  }) {
    cleanupCalled = true;
    if (creationToken != _creationToken || _createdPath == null) return false;
    final Directory partial = Directory(_createdPath!);
    if (partial.existsSync()) partial.deleteSync(recursive: true);
    return true;
  }
}
