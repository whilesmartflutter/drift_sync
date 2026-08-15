class LocalSyncMetadata {
  final String entityType;
  final DateTime? lastSyncedAt;
  final DateTime? lastAttemptedAt;
  final String? lastError;

  LocalSyncMetadata({
    required this.entityType,
    this.lastSyncedAt,
    this.lastAttemptedAt,
    this.lastError,
  });
}
