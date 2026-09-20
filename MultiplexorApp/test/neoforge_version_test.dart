import 'package:multiplexor/models/neoforge_version.dart';
import 'package:test/test.dart';

void main() {
  test('maps NeoForge loaders to exact released Minecraft versions', () {
    for (final MapEntry<String, String> fixture in <String, String>{
      '20.1.117': '1.20.1',
      '21.0.167': '1.21',
      '21.1.234': '1.21.1',
      '26.1.2.64': '26.1.2',
      '26.2.0.1-beta': '26.2',
      '26.3.0.7-beta': '26.3',
      '26.3.1.1-beta': '26.3.1',
    }.entries) {
      expect(minecraftVersionFromNeoForgeLoader(fixture.key), fixture.value);
    }
  });

  test('rejects malformed and ambiguous loader ids', () {
    for (final String loader in <String>[
      '',
      '26.3',
      '26.3.7',
      '21.1.2.3',
      '26.3.0.7-snapshot',
      '26.3.0.7-beta-extra',
    ]) {
      expect(minecraftVersionFromNeoForgeLoader(loader), isNull);
    }
  });
}
