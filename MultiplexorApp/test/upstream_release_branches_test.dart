import 'package:multiplexor/models/upstream_release_branches.dart';
import 'package:test/test.dart';

void main() {
  test('release branches list stable versions in version order', () {
    const String refs = '''
3c591d7020b402fa38430cb57ffd1d29b61681a3\trefs/heads/ver/26.1.2
0ff899dae303f986b86ae9c520e477d9a02f5b92\trefs/heads/ver/1.21.9
6f512cec7d988ae9449ed79553a9b4ac75de60f2\trefs/heads/ver/26.2
8cffa9059ad6bbc2b28510c38ed61a51098d4971\trefs/heads/ver/26.3.x
73f443461b5c9c806cf423e87eccb54fee4b12e1\trefs/heads/ver/hardfork-paper
0008a68c1be431a9253cfd23ac778ffbc4d78cc4\trefs/heads/ver/nopetal/1.19.2
e4d6dfd1597968e78a3d405dce73d1d1f14a4b81\trefs/heads/ver/1.21.10
66f99f8eb21628892b47671375884e97052ba52b\trefs/heads/master
''';

    expect(upstreamReleaseVersions(refs), <String>[
      '1.21.9',
      '1.21.10',
      '26.1.2',
      '26.2',
    ]);
  });

  test('release branches of an unreachable repository are empty', () {
    expect(upstreamReleaseVersions(''), isEmpty);
  });

  test('every git-versioned server type names its upstream repository', () {
    expect(
      <String>[
        for (String type in upstreamRepositoryTypes)
          upstreamRepositoryUrl(type),
      ],
      <String>[
        'https://github.com/PaperMC/Paper.git',
        'https://github.com/PurpurMC/Purpur.git',
        'https://github.com/PaperMC/Folia.git',
        'https://github.com/CraftCanvasMC/Canvas.git',
        'https://github.com/Winds-Studio/Leaf.git',
      ],
    );
  });
}
