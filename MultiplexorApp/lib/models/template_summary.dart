class TemplateSummary {
  const TemplateSummary({
    required this.name,
    required this.type,
    this.minecraft,
    this.kind = 'server',
    this.description = '',
    this.bundled = false,
    this.buildTypes = const <String>[],
    this.backendCount = 0,
  });

  final String name;
  final String type;
  final String? minecraft;
  final String kind;
  final String description;
  final bool bundled;
  final List<String> buildTypes;
  final int backendCount;
}
