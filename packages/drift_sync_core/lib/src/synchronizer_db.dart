import 'package:drift_sync_core/drift_sync_core.dart';

/// A server-delivered entity whose local dependencies were not met at
/// persist time, stored (marshalled) until they are.
final class ParkedRemoteItem {
  const ParkedRemoteItem({
    required this.entityType,
    required this.clientId,
    required this.data,
    this.parkedAt,
  });

  final String entityType;
  final String clientId;
  final Map<String, dynamic> data;
  final DateTime? parkedAt;
}

/// Contract a consumer database implements so the orchestrator can persist
/// pending changes, sync metadata, and run transactional commits.
///
/// Drift consumers typically apply this as a mixin on their `_$AppDatabase`
/// class — Drift's `GeneratedDatabase.transaction` already satisfies the
/// transaction method.
mixin SynchronizerDb {
  Future<List<PendingLocalChange>> getPendingLocalChanges();
  Future<void> cancelAllLocalChanges();
  Future<void> clearDatabase();
  /// Concludes an upload attempt. With [error] set the change stays queued
  /// for retry (implementations should increment its attempt count); with
  /// [quarantine] also true the change is permanently parked — excluded from
  /// [getPendingLocalChanges] — for human review.
  Future<void> concludeLocalChange(
    PendingLocalChange localChange, {
    Object? error,
    bool persistedToRemote = false,
    bool quarantine = false,
  });
  Future<List<LocalSyncMetadata>> getLocalSyncMetadataList();
  Future<LocalSyncMetadata?> getLocalSyncMetadata(String id);
  Future<void> insertLocalChange(PendingLocalChange localChange);

  Future<void> concludeEntityLocalChanges(
    String entityType,
    int? entityId,
    Operation operation,
  );

  Future<void> updateEntityLocalSyncMetadata({
    required String entityType,
    DateTime? lastSyncedAt,
  });

  Future<R> transaction<R>(Future<R> Function() body, {bool requireNew = false});

  /// Parking store for down-synced items deferred by
  /// [SyncTypeHandler.shouldPersistLocal]. The defaults are no-ops (parking
  /// disabled); a consumer must override all three with persistent storage
  /// before any handler overrides [SyncTypeHandler.shouldPersistLocal], or
  /// deferred items are dropped (the cursor has already advanced past them).
  Future<void> parkRemoteItem(ParkedRemoteItem item) async {}
  Future<List<ParkedRemoteItem>> getParkedRemoteItems(
    String entityType,
  ) async =>
      const [];
  Future<void> unparkRemoteItem(String entityType, String clientId) async {}

  /// Default impl bridges to [getLocalSyncMetadata]. Override to surface
  /// richer state once you add columns for it.
  Future<EntitySyncState> getEntitySyncState(String entityType) async {
    final meta = await getLocalSyncMetadata(entityType);
    if (meta == null || meta.lastSyncedAt == null) {
      return const NeverSynced();
    }
    return Healthy(lastSync: DateTime.now(), cursor: meta.lastSyncedAt);
  }

  /// Default impl bridges the cursor to [updateEntityLocalSyncMetadata].
  /// Override to persist a wall-clock `lastSync` or any richer state.
  Future<void> updateEntitySyncState(
    String entityType,
    EntitySyncState state,
  ) async {
    switch (state) {
      case Healthy(:final cursor):
        if (cursor != null) {
          await updateEntityLocalSyncMetadata(
            entityType: entityType,
            lastSyncedAt: cursor,
          );
        }
      case NeverSynced():
        break;
    }
  }
}
