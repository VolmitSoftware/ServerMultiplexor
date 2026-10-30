const List<String> upstreamRepositoryTypes = <String>[
  'paper',
  'purpur',
  'folia',
  'canvas',
  'leaf',
];

String upstreamRepositoryUrl(String type) {
  return switch (type) {
    'paper' => 'https://github.com/PaperMC/Paper.git',
    'purpur' => 'https://github.com/PurpurMC/Purpur.git',
    'folia' => 'https://github.com/PaperMC/Folia.git',
    'canvas' => 'https://github.com/CraftCanvasMC/Canvas.git',
    'leaf' => 'https://github.com/Winds-Studio/Leaf.git',
    _ => throw ArgumentError.value(type, 'type', 'No upstream repository'),
  };
}

List<String> upstreamReleaseVersions(String refs) {
  final RegExp branch = RegExp(r'\srefs/heads/ver/(\d+\.\d+(?:\.\d+)?)$');
  final List<String> versions = <String>{
    for (String line in refs.split('\n'))
      if (branch.firstMatch(line.trim()) case RegExpMatch match)
        match.group(1)!,
  }.toList()..sort(_compareVersions);
  return versions;
}

int _compareVersions(String left, String right) {
  final List<int> a = left.split('.').map(int.parse).toList();
  final List<int> b = right.split('.').map(int.parse).toList();
  for (int i = 0; i < 3; i++) {
    final int difference =
        (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
    if (difference != 0) {
      return difference;
    }
  }
  return 0;
}
