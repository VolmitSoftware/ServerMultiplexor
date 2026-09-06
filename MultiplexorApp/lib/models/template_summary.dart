class TemplateSummary {
  const TemplateSummary({
    required this.name,
    required this.type,
    this.minecraft,
  });

  final String name;
  final String type;
  final String? minecraft;
}
