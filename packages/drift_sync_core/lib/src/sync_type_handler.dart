import 'dart:async';

import 'package:drift_sync_core/src/persist_outcome.dart';
import 'package:drift_sync_core/src/sync_commit_tx.dart';

abstract class SyncTypeHandler<TEntity, TKey, TServerKey> {
  String get entityType;

  /// If true, the synchronizer skips down-sync (getAllRemote / upsert / delete) for this handler.
  /// Use for entity types that are only pushed (e.g. media that comes with transactions).
  bool get skipDownSync => false;

  bool get canSyncWithoutDependencies => false;

  // Get the client ID (string) from an entity
  String getClientId(TEntity entity);

  // Get the server ID (int) from an entity
  int? getServerId(TEntity entity);

  // Get the server ID (int) from an entity
  DateTime? getLastSyncedAt(TEntity entity);

  /// Timestamp used to advance the down-sync cursor after persisting a page.
  ///
  /// Must be on the same timeline the server filters `synced_since` against
  /// (typically `updated_at`); otherwise rows whose filter field is ahead of
  /// the cursor are re-fetched on every sync forever. Defaults to
  /// [getLastSyncedAt] for backwards compatibility.
  DateTime? getCursorTimestamp(TEntity entity) => getLastSyncedAt(entity);

  // Get the revision from an entity
  String getRev(TEntity entity);

  //Future<TEntity> getLocal(TKey id);
  // Get entity by client ID
  Future<TEntity> getLocalByClientId(TKey clientId);

  // Get entity by server ID
  Future<TEntity?> getLocalByServerId(TServerKey serverId);

  Future<void> upsertLocal(TEntity entity);
  Future<void> upsertAllLocal(List<TEntity> list);
  // Future<void> updateLocalSyncMetadata(TEntity entity);

  /// Whether [entity], as delivered by the server, can be persisted locally
  /// right now.
  ///
  /// Return false when a local dependency (e.g. a referenced parent row) is
  /// not present yet — the orchestrator parks the item via
  /// [SynchronizerDb.parkRemoteItem] and retries it on later cycles, so the
  /// consumer database must implement the parking contract before a handler
  /// overrides this. Deletions should always return true.
  Future<bool> shouldPersistLocal(TEntity entity) async => true;

  /// Persist a single entity. Equivalent to [persistLocal] with a one-item
  /// list, but constructs the list inside the type-parameterized scope so
  /// orchestrator callers (which see the handler dynamic-erased) don't
  /// hit `List<dynamic>` vs `List<TEntity>` runtime checks.
  Future<PersistOutcome<TEntity>> persistOne(
    TEntity entity,
    SyncCommitTx tx,
  ) {
    return persistLocal(<TEntity>[entity], tx);
  }

  /// Persist a batch to local storage and return a typed outcome the
  /// orchestrator uses to advance its cursor.
  ///
  /// Default impl reports entities with an empty `clientId` as [Skipped]
  /// ([MissingClientId]), defers entities failing [shouldPersistLocal]
  /// ([DependencyNotReady]), and writes the rest via [upsertAllLocal]
  /// inside [tx]. Override to track real per-item failures or
  /// stale-revision skips.
  Future<PersistOutcome<TEntity>> persistLocal(
    List<TEntity> entities,
    SyncCommitTx tx,
  ) async {
    final persisted = <TEntity>[];
    final skipped = <Skipped<TEntity>>[];
    DateTime? cursor;

    for (final entity in entities) {
      // Skipped rows still advance the cursor: they were returned by the
      // server, so leaving the cursor behind them would re-fetch them on
      // every sync. Empty-clientId rows are claimed by client-id
      // reconciliation; dependency-deferred rows are parked and retried.
      final ts = getCursorTimestamp(entity);
      if (ts != null && (cursor == null || ts.isAfter(cursor))) {
        cursor = ts;
      }

      if (getClientId(entity).isEmpty) {
        skipped.add(Skipped(item: entity, reason: const MissingClientId()));
        continue;
      }
      if (!await shouldPersistLocal(entity)) {
        skipped.add(Skipped(item: entity, reason: const DependencyNotReady()));
        continue;
      }
      persisted.add(entity);
    }

    await tx.runWrite(() async {
      await upsertAllLocal(persisted);
    });

    return PersistOutcome<TEntity>(
      persisted: persisted,
      skipped: skipped,
      cursorAdvanceTo: cursor,
    );
  }

  Future<void> deleteLocal(TEntity entity);
  Future<void> deleteAllLocal();
  Future<void> deleteLocalNotIn(Set<String> clientIds);

  // Get remote entity by server ID
  //Future<TEntity?> getRemote(TKey id);
  Future<TEntity?> getRemote(TServerKey serverId);
  Future<List<TEntity>> getAllRemote({DateTime? syncedSince, bool? noClientId});
  // Future<List<TEntity>> getRemoteChangeByTime(DateTime time);
  Future<TEntity> putRemote(TEntity entity);
  Future<void> deleteRemote(TEntity entity);

  /// Pushes a freshly assigned client id for a server-created entity during
  /// client-id reconciliation.
  ///
  /// Defaults to [putRemote] (full update). Override to send a minimal
  /// payload (client id + updated_at) so business validation on unrelated
  /// fields can never veto the claim. Must return the updated entity as the
  /// server now stores it.
  Future<TEntity> claimClientId(TEntity entity) => putRemote(entity);

  Future<TEntity> unmarshal(Map<String, dynamic> entityBytes);
  Map<String, dynamic> marshal(TEntity entity);

  Future<bool> shouldPersistRemote(TEntity entity);

  Future<TEntity> assignClientId(TEntity item);

  List<TEntity> getEmptyList() {
    return List<TEntity>.empty(growable: true);
  }
}

/// Optional capability for handlers that can stream remote entities in pages.
///
/// This allows the synchronizer to process changes incrementally instead of
/// loading all remote items into memory at once.
abstract class PagedSyncTypeHandler<TEntity> {
  Stream<List<TEntity>> getAllRemoteStream(
      {DateTime? syncedSince, bool? noClientId});
}
