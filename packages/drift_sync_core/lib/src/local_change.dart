class PendingLocalChange {
  final String entityType;
  final String entityId;
  final String entityRev;
  final bool deleted;
  // final Uint8List protoBytes;
  final Map<String, dynamic> data;

  final DateTime createMoment;
  final bool concluded;
  final DateTime? concludedMoment;
  final String? error;
  final bool dismissed;

  /// Failed upload attempts so far; drives the unknown-failure escalation
  /// budget.
  final int attemptCount;

  /// Set when the change was classified as permanently failed; quarantined
  /// changes are never retried.
  final DateTime? quarantinedAt;

  PendingLocalChange({
    required this.createMoment,
    required this.entityType,
    required this.entityId,
    required this.entityRev,
    required this.data,
    required this.deleted,
    this.concluded = false,
    this.concludedMoment,
    this.error,
    this.dismissed = false,
    this.attemptCount = 0,
    this.quarantinedAt,
  });

  factory PendingLocalChange.put({
    required String entityType,
    // required Uint8List protoBytes,
    required Map<String, dynamic> entityData,
    required String entityId,
    required String entityRev,
  }) {
    return PendingLocalChange(
      createMoment: DateTime.now(),
      deleted: false,
      entityType: entityType,
      data: entityData,
      entityId: entityId,
      entityRev: entityRev,
      concluded: false,
      concludedMoment: null,
      error: null,
      dismissed: false,
    );
  }

  factory PendingLocalChange.delete({
    required String entityType,
    required Map<String, dynamic> data,
    required String entityId,
    required String entityRev,
  }) {
    return PendingLocalChange(
      createMoment: DateTime.now(),
      deleted: true,
      entityType: entityType,
      data: data,
      entityId: entityId,
      entityRev: entityRev,
      concluded: false,
      concludedMoment: null,
      error: null,
      dismissed: false,
    );
  }

  PendingLocalChange copyWith({
    int? id,
    String? entityType,
    String? entityId,
    String? entityRev,
    bool? deleted,
    Map<String, dynamic>? entityData,
    DateTime? createMoment,
    bool? concluded,
    DateTime? concludedMoment,
    String? error,
    bool? dismissed,
    int? attemptCount,
    DateTime? quarantinedAt,
  }) {
    return PendingLocalChange(
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      entityRev: entityRev ?? this.entityRev,
      deleted: deleted ?? this.deleted,
      data: entityData ?? data,
      createMoment: createMoment ?? this.createMoment,
      concluded: concluded ?? this.concluded,
      concludedMoment: concludedMoment ?? this.concludedMoment,
      error: error ?? this.error,
      dismissed: dismissed ?? this.dismissed,
      attemptCount: attemptCount ?? this.attemptCount,
      quarantinedAt: quarantinedAt ?? this.quarantinedAt,
    );
  }
}
