/// Result of [SyncTypeHandler.persistLocal]. The orchestrator reads
/// [cursorAdvanceTo] from this; it never recomputes from the input list.
final class PersistOutcome<TEntity> {
  const PersistOutcome({
    required this.persisted,
    required this.skipped,
    required this.cursorAdvanceTo,
  });

  final List<TEntity> persisted;
  final List<Skipped<TEntity>> skipped;

  /// Cursor to commit to sync metadata. `null` means leave the existing
  /// cursor unchanged.
  final DateTime? cursorAdvanceTo;

  static PersistOutcome<T> empty<T>() => PersistOutcome<T>(
        persisted: const [],
        skipped: const [],
        cursorAdvanceTo: null,
      );
}

final class Skipped<TEntity> {
  const Skipped({required this.item, required this.reason});

  final TEntity item;
  final SkipReason reason;
}

sealed class SkipReason {
  const SkipReason();
}

/// Item arrived without a `client_id`; client-id reconciliation claims it
/// on a later cycle, so the cursor may advance past it safely.
final class MissingClientId extends SkipReason {
  const MissingClientId();
}

/// [SyncTypeHandler.shouldPersistLocal] returned false: a local dependency
/// (e.g. a referenced parent row) is not present yet. The orchestrator parks
/// the item and retries it on later cycles.
final class DependencyNotReady extends SkipReason {
  const DependencyNotReady();
}
