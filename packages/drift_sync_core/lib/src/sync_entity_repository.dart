import 'dart:async';

import 'package:drift_sync_core/drift_sync_core.dart';
import 'package:meta/meta.dart';

/// Abstract interface for request authorization service
abstract class RequestAuthorizationService {
  Future<bool> canSync();
}

enum DataSource { remote, local }

enum Operation { put, delete }

enum DataDestination { local, both }

/// Provides methods to get, create, update and delete
/// entities of type TEntity.
///
/// Each of these
/// methods works by attempting to first use
/// online data with the fallback of the offline data.
abstract class SyncEntityRepository<TAppDatabase extends SynchronizerDb,
    TEntity, TKey, TServerKey> {
  const SyncEntityRepository({
    required this.syncHandler,
    required this.db,
    required this.requestAuthorizationService,
  });

  final SyncTypeHandler<TEntity, TKey, TServerKey> syncHandler;
  final TAppDatabase db;
  final RequestAuthorizationService requestAuthorizationService;

  Future<void> enqueuePut(TEntity entity) {
    return db.insertLocalChange(_pendingPut(entity));
  }

  @protected
  Future<TEntity> persistAndPost(
    Future<TEntity> Function() persistLocal,
  ) async {
    return _persistAndQueue(persistLocal, create: true);
  }

  @protected
  Future<TEntity> persistAndPut(
    Future<TEntity> Function() persistLocal,
  ) async {
    return _persistAndQueue(persistLocal, create: false);
  }

  Future<TEntity> _persistAndQueue(
    Future<TEntity> Function() persistLocal, {
    required bool create,
  }) async {
    late TEntity entity;
    late PendingLocalChange pending;
    await db.transaction(() async {
      entity = await persistLocal();
      pending = _pendingPut(entity);
      await db.insertLocalChange(pending);
    });
    unawaited(_attemptPut(entity, pending, create: create));
    return entity;
  }

  @protected
  Future<TEntity?> getRemote(TServerKey id) async {
    try {
      return await syncHandler.getRemote(id);
    } on UnavailableException {
      return null;
    }
  }

  /// Outbox ordering: the pending change is enqueued BEFORE the remote
  /// attempt, so no failure mode (server rejection, crash mid-request) can
  /// leave a local record invisible to the sync loop. Success removes the
  /// queued row; failure records the error on it, handing retry/backoff/
  /// quarantine to the synchronizer.
  Future<(TEntity, DataDestination)> put(TEntity entity) async {
    final pending = _pendingPut(entity);
    await db.transaction(() => db.insertLocalChange(pending));
    return _attemptPut(entity, pending, create: false);
  }

  Future<(TEntity, DataDestination)> post(TEntity entity) async {
    final pending = _pendingPut(entity);
    await db.transaction(() => db.insertLocalChange(pending));
    return _attemptPut(entity, pending, create: true);
  }

  Future<(TEntity, DataDestination)> _attemptPut(
    TEntity entity,
    PendingLocalChange pending, {
    required bool create,
  }) async {
    try {
      final canSync = await requestAuthorizationService.canSync();
      final serverId = syncHandler.getServerId(entity);
      if (!canSync || (!create && serverId == null)) {
        return (entity, DataDestination.local);
      }

      final remoteCreated = await putRemote(entity);
      if (remoteCreated == null) {
        return (entity, DataDestination.local);
      }
      await _concludePutSuccess(pending, remoteCreated);
      return (remoteCreated, DataDestination.both);
    } catch (error) {
      await db.concludeLocalChange(pending, error: error);
      return (entity, DataDestination.local);
    }
  }

  PendingLocalChange _pendingPut(TEntity entity) {
    return PendingLocalChange.put(
      entityData: syncHandler.marshal(entity),
      entityType: syncHandler.entityType,
      entityId: syncHandler.getClientId(entity),
      entityRev: syncHandler.getRev(entity),
    );
  }

  Future<void> _concludePutSuccess(
      PendingLocalChange pending, TEntity remoteCreated) async {
    await db.transaction(() async {
      await db.concludeLocalChange(pending, persistedToRemote: true);
      await db.concludeEntityLocalChanges(
        syncHandler.entityType,
        syncHandler.getServerId(remoteCreated),
        Operation.put,
      );
      await syncHandler.upsertLocal(remoteCreated);
    });
  }

  @protected
  Future<TEntity?> putRemote(TEntity entity) async {
    try {
      if (await syncHandler.shouldPersistRemote(entity)) {
        return await syncHandler.putRemote(entity);
      }
      return null;
    } on UnavailableException {
      // Graceful fallback to local storage when network is unavailable
      return null;
    }
    // Other exceptions propagate to put/post, which record them on the
    // already-enqueued pending change.
  }

  /// Same outbox ordering as [put]/[post]: the delete change is enqueued
  /// (replacing any queued put for the same entity) before the remote
  /// attempt. A record the server never knew about concludes immediately.
  Future<DataDestination> delete(TEntity entity) async {
    final pending = PendingLocalChange.delete(
      entityType: syncHandler.entityType,
      data: syncHandler.marshal(entity),
      entityId: syncHandler.getClientId(entity),
      entityRev: syncHandler.getRev(entity),
    );
    await db.transaction(() async {
      await syncHandler.deleteLocal(entity);
      await db.insertLocalChange(pending);
    });

    if (syncHandler.getServerId(entity) == null) {
      await db.concludeLocalChange(pending, persistedToRemote: true);
      return DataDestination.local;
    }

    final canSync = await requestAuthorizationService.canSync();
    bool synced = false;
    if (canSync) {
      try {
        synced = await deleteRemote(entity);
      } catch (error) {
        await db.concludeLocalChange(pending, error: error);
        return DataDestination.local;
      }
    }

    if (!synced) {
      return DataDestination.local;
    }
    await db.transaction(() async {
      await db.concludeLocalChange(pending, persistedToRemote: true);
      await _concludeDeleteChanges(entity);
    });
    return DataDestination.both;
  }

  Future<void> _concludeDeleteChanges(TEntity entity) async {
    await db.concludeEntityLocalChanges(
      syncHandler.entityType,
      syncHandler.getServerId(entity),
      Operation.delete,
    );
  }

  Future<bool> deleteRemote(TEntity entity) async {
    try {
      await syncHandler.deleteRemote(entity);
      return true;
    } on UnavailableException {
      // Graceful fallback to local storage when network is unavailable
      return false;
    }
    // Other exceptions propagate to delete, which records them on the
    // already-enqueued pending change.
  }
}
