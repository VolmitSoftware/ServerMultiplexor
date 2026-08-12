import 'dart:io';

import 'package:multiplexor/services/pterodactyl/pterodactyl_profile.dart';
import 'package:multiplexor/services/pterodactyl/pterodactyl_profile_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('normalizes an HTTPS origin and rejects unsafe URLs', () {
    final PterodactylProfile profile = PterodactylProfile(
      id: ' DEV ',
      name: 'Development',
      panelUri: Uri.parse('https://dev.volmitsoftware.com:443/'),
    );

    expect(profile.id, 'dev');
    expect(profile.origin, 'https://dev.volmitsoftware.com');
    expect(
      () => PterodactylProfile(
        id: 'bad',
        name: 'Bad',
        panelUri: Uri.parse('http://example.test'),
      ),
      throwsFormatException,
    );
  });

  test('round-trips only non-secret profile fields', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-profile-store-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final String metadataPath = p.join(temporary.path, '.multiplexor');
    final PterodactylProfileStore store = PterodactylProfileStore(metadataPath);
    final PterodactylProfile profile = PterodactylProfile(
      id: 'dev',
      name: 'Development',
      panelUri: Uri.parse('https://dev.volmitsoftware.com'),
    );

    store.save(profile);

    expect(store.load('dev'), profile);
    final String document = File(
      p.join(metadataPath, 'pterodactyl-profiles.yaml'),
    ).readAsStringSync();
    expect(document, isNot(contains('credential')));
    expect(document, isNot(contains('api_key')));
  });

  test('rejects unknown fields rather than accepting token-shaped data', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-profile-store-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final File file = File(p.join(temporary.path, 'profiles.yaml'))
      ..writeAsStringSync('''
schema_version: 1
profiles:
  - id: dev
    name: Development
    panel_url: https://dev.volmitsoftware.com
    api_key: must-not-be-loaded
''');

    expect(
      () => PterodactylProfileStore.atFile(file).loadAll(),
      throwsFormatException,
    );
  });
}
