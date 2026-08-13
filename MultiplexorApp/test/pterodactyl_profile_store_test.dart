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
    expect(store.loadActiveId(), 'dev');
    final String document = File(
      p.join(metadataPath, 'pterodactyl-profiles.yaml'),
    ).readAsStringSync();
    expect(document, isNot(contains('credential')));
    expect(document, isNot(contains('api_key')));
  });

  test('persists the selected account and advances it after removal', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-profile-active-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final PterodactylProfileStore store = PterodactylProfileStore(
      temporary.path,
    );
    final PterodactylProfile alpha = PterodactylProfile(
      id: 'alpha',
      name: 'Alpha',
      panelUri: Uri.parse('https://alpha.example.test'),
    );
    final PterodactylProfile beta = PterodactylProfile(
      id: 'beta',
      name: 'Beta',
      panelUri: Uri.parse('https://beta.example.test'),
    );

    store
      ..save(alpha)
      ..save(beta)
      ..setActive('beta');

    expect(store.loadActiveId(), 'beta');
    expect(store.remove('beta'), isTrue);
    expect(store.loadActiveId(), 'alpha');
  });

  test('loads schema v1 profiles with the first account selected', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-profile-legacy-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final File file = File(p.join(temporary.path, 'profiles.yaml'))
      ..writeAsStringSync('''
schema_version: 1
profiles:
  - id: beta
    name: Beta
    panel_url: https://beta.example.test
  - id: alpha
    name: Alpha
    panel_url: https://alpha.example.test
''');
    final PterodactylProfileStore store = PterodactylProfileStore.atFile(file);

    expect(store.loadAll().map((PterodactylProfile item) => item.id), <String>[
      'alpha',
      'beta',
    ]);
    expect(store.loadActiveId(), 'alpha');
  });

  test('rejects a selected account that does not exist', () {
    final Directory temporary = Directory.systemTemp.createTempSync(
      'multiplexor-profile-invalid-active-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final File file = File(p.join(temporary.path, 'profiles.yaml'))
      ..writeAsStringSync('''
schema_version: 2
active_profile: missing
profiles:
  - id: dev
    name: Development
    panel_url: https://dev.example.test
''');

    expect(
      () => PterodactylProfileStore.atFile(file).loadAll(),
      throwsFormatException,
    );
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
