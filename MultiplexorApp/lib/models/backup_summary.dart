class BackupSummary {
  const BackupSummary({
    required this.id,
    required this.label,
    required this.createdAt,
  });

  final String id;
  final String label;
  final DateTime createdAt;
}
