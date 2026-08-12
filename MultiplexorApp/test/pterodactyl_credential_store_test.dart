import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_credential.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_credential_store.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:test/test.dart';

void main() {
  final PterodactylProfile profile = PterodactylProfile(
    id: 'dev',
    name: 'Development',
    panelUri: Uri.parse('https://dev.volmitsoftware.com'),
  );

  test('uses the stable origin-bound Keychain identity', () {
    expect(
      PterodactylCredentialStore.keychainService,
      'com.volmit.multiplexor.pterodactyl',
    );
    expect(
      PterodactylCredentialStore.keychainAccountFor(
        profile,
        PterodactylCredentialRole.client,
      ),
      'v1:dev:client:https://dev.volmitsoftware.com',
    );
  });

  test('redacts credentials and rejects whitespace injection', () {
    const String token = 'ptlc_super_secret';
    final PterodactylCredential credential = PterodactylCredential(token);

    expect(credential.toString(), isNot(contains(token)));
    expect(
      () => PterodactylCredential('$token\nHeader: bad'),
      throwsFormatException,
    );
  });

  test('caches a validated environment credential for the session', () async {
    final String credentialVariable =
        PterodactylCredentialStore.environmentVariableFor(
          profile,
          PterodactylCredentialRole.client,
        );
    final String originVariable =
        PterodactylCredentialStore.environmentOriginVariableFor(profile);
    final Map<String, String> environment = <String, String>{
      credentialVariable: 'ptlc_environment',
      originVariable: profile.origin,
    };
    final PterodactylCredentialStore store = PterodactylCredentialStore(
      '/unused/.multiplexor',
      environment: environment,
    );

    expect(
      (await store.read(profile, PterodactylCredentialRole.client))?.value,
      'ptlc_environment',
    );
    environment.clear();
    expect(
      (await store.read(profile, PterodactylCredentialRole.client))?.value,
      'ptlc_environment',
    );
  });

  test('session credentials take precedence over environment', () async {
    final String credentialVariable =
        PterodactylCredentialStore.environmentVariableFor(
          profile,
          PterodactylCredentialRole.client,
        );
    final String originVariable =
        PterodactylCredentialStore.environmentOriginVariableFor(profile);
    final PterodactylCredentialStore store = PterodactylCredentialStore(
      '/unused/.multiplexor',
      environment: <String, String>{
        credentialVariable: 'ptlc_environment',
        originVariable: profile.origin,
      },
    );
    store.putForSession(
      profile,
      PterodactylCredentialRole.client,
      PterodactylCredential('ptlc_session'),
    );

    expect(
      (await store.read(profile, PterodactylCredentialRole.client))?.value,
      'ptlc_session',
    );
  });

  test('environment IDs distinguish hyphens from underscores', () {
    final PterodactylProfile hyphenated = PterodactylProfile(
      id: 'panel-east',
      name: 'East',
      panelUri: Uri.parse('https://east.example.com'),
    );
    final PterodactylProfile underscored = PterodactylProfile(
      id: 'panel_east',
      name: 'East alternate',
      panelUri: Uri.parse('https://alternate.example.com'),
    );

    expect(
      PterodactylCredentialStore.environmentVariableFor(
        hyphenated,
        PterodactylCredentialRole.client,
      ),
      'MULTIPLEXOR_PTERODACTYL_PANEL_2DEAST_CLIENT_API_KEY',
    );
    expect(
      PterodactylCredentialStore.environmentVariableFor(
        underscored,
        PterodactylCredentialRole.client,
      ),
      'MULTIPLEXOR_PTERODACTYL_PANEL_5FEAST_CLIENT_API_KEY',
    );
  });

  test('rejects an environment credential without its exact origin', () async {
    final String credentialVariable =
        PterodactylCredentialStore.environmentVariableFor(
          profile,
          PterodactylCredentialRole.client,
        );
    final String originVariable =
        PterodactylCredentialStore.environmentOriginVariableFor(profile);

    for (final Map<String, String> environment in <Map<String, String>>[
      <String, String>{credentialVariable: 'ptlc_environment'},
      <String, String>{
        credentialVariable: 'ptlc_environment',
        originVariable: 'https://other.example.com',
      },
    ]) {
      final PterodactylCredentialStore store = PterodactylCredentialStore(
        '/unused/.multiplexor',
        environment: environment,
      );
      await expectLater(
        store.read(profile, PterodactylCredentialRole.client),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.toString(),
            'message',
            allOf(
              contains(originVariable),
              isNot(contains('ptlc_environment')),
            ),
          ),
        ),
      );
    }
  });

  test('caches a successful Keychain read for the session', () async {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-keychain-test-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final File executable = File('${temporary.path}/security-stub')
      ..writeAsStringSync('''#!/bin/sh
printf x >> "\$0.count"
printf ptlc_keychain
''');
    final ProcessResult chmod = Process.runSync('chmod', <String>[
      '700',
      executable.path,
    ]);
    expect(chmod.exitCode, 0);
    final PterodactylCredentialStore store = PterodactylCredentialStore(
      '/unused/.multiplexor',
      environment: const <String, String>{},
      securityExecutable: executable.path,
    );

    expect(
      (await store.read(profile, PterodactylCredentialRole.client))?.value,
      'ptlc_keychain',
    );
    expect(
      (await store.read(profile, PterodactylCredentialRole.client))?.value,
      'ptlc_keychain',
    );
    expect(File('${executable.path}.count').readAsStringSync(), 'x');
  }, skip: !Platform.isMacOS);

  test(
    'successful enrollment invalidates a previously cached credential',
    () async {
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-keychain-enroll-test-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final File executable = File('${temporary.path}/security-stub')
        ..writeAsStringSync('''#!/bin/sh
if [ "\$1" = "find-generic-password" ]; then
  printf ptlc_replaced
fi
''');
      final ProcessResult chmod = Process.runSync('chmod', <String>[
        '700',
        executable.path,
      ]);
      expect(chmod.exitCode, 0);
      final PterodactylCredentialStore store = PterodactylCredentialStore(
        '/unused/.multiplexor',
        environment: const <String, String>{},
        securityExecutable: executable.path,
      );
      store.putForSession(
        profile,
        PterodactylCredentialRole.client,
        PterodactylCredential('ptlc_old'),
      );

      await store.enroll(profile, PterodactylCredentialRole.client);

      expect(
        (await store.read(profile, PterodactylCredentialRole.client))?.value,
        'ptlc_replaced',
      );
    },
    skip: !Platform.isMacOS,
  );

  test(
    'rollback restore sends the credential on stdin, never argv',
    () async {
      final Directory temporary = Directory.systemTemp.createTempSync(
        'multiplexor-keychain-restore-test-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));
      final File executable = File('${temporary.path}/security-stub')
        ..writeAsStringSync('''#!/bin/sh
printf '%s\n' "\$@" > "\$0.args"
IFS= read -r secret || true
printf '%s' "\$secret" > "\$0.stdin"
''');
      final ProcessResult chmod = Process.runSync('chmod', <String>[
        '700',
        executable.path,
      ]);
      expect(chmod.exitCode, 0);
      final PterodactylCredentialStore store = PterodactylCredentialStore(
        '/unused/.multiplexor',
        environment: const <String, String>{},
        securityExecutable: executable.path,
      );
      const String value = 'ptlc_restore_only_on_stdin';

      await store.restore(
        profile,
        PterodactylCredentialRole.client,
        PterodactylCredential(value),
      );

      expect(File('${executable.path}.stdin').readAsStringSync(), value);
      expect(
        File('${executable.path}.args').readAsStringSync(),
        isNot(contains(value)),
      );
      expect(
        (await store.read(profile, PterodactylCredentialRole.client))?.value,
        value,
      );
    },
    skip: !Platform.isMacOS,
  );
}
