# Changelog

## 0.3.4

### Fixed

* Local persistence and its outbox entry can be committed together while the
  remote attempt continues in the background.
* Handlers that can park missing dependencies may continue downloading after
  an earlier dependency fails.
* Empty and failed model downloads expose their latest attempt to clients.
* The dependency bypass is honoured by both download phases. It previously
  applied only to the time-based resync, so `downloadModelsWithNoClientIds`
  kept skipping opted-in dependents — leaving server rows without a client
  id unclaimed, and therefore dropped by regular download, for as long as a
  dependency kept failing.

### Changed

* `SyncTypeHandler.canSyncWithoutDependencies` is renamed
  `downloadIgnoresFailedDependencies`. It affects down-sync only — uploads
  are gated by `shouldPersistRemote` — and only the failure cascade, not the
  dependency relationship. Unreleased in any tagged version, so no consumer
  is affected. Only safe on handlers that override `shouldPersistLocal` to
  park rows whose references are not yet local.

### Added

* `SyncEntityRepository.persistAndDelete()`, the counterpart to
  `persistAndPost`/`persistAndPut`. Returns once the local deletion and its
  outbox entry are durable, leaving the remote call to finish in the
  background, so UI paths are not held for a network round trip. `delete()`
  is unchanged for callers that need the `DataDestination` result.

## 0.3.3

### Fixed

* A queued payload that fails to unmarshal now throws `UnmarshalException`,
  classified permanent — quarantined and surfaced on the first attempt
  instead of burning the unknown-failure retry budget.
* A change deferred by `shouldPersistRemote` now records a transient
  `DependencyPendingException` on the row, so sync history can show why it
  is waiting instead of leaving it silently pending.

## 0.3.2

### Improved

* `upload_local_change` crash reports now include the attempt number and
  a truncated excerpt of the queued payload, so serialization failures
  (e.g. null type casts during unmarshal) are diagnosable from the crash
  report alone.

## 0.3.1

### Fixed

* `SyncEntityRepository.put()`/`post()`/`delete()` now enqueue the pending
  local change *before* attempting the remote call (outbox ordering).
  Previously any non-`UnavailableException` failure — e.g. a server
  validation rejection — escaped before the pending change was written,
  permanently orphaning the record: saved locally but invisible to the sync
  loop, never retried, never quarantined, absent from sync history. Remote
  failures are now recorded on the queued change, handing retry/backoff/
  quarantine to the synchronizer, and these methods no longer rethrow.
* `delete()` of a never-synced entity (no server id) no longer calls
  `deleteRemote`; the change concludes immediately, also removing any
  queued put for the same entity.

## 0.2.0

### Behavioral change

* `DriftSynchronizer.sync()` is now idempotent: if a sync is already in
  progress, it returns the in-flight `Future` instead of throwing
  `InvalidStateException`. Callers (timers, lifecycle hooks, push
  handlers, refresh gestures) can invoke `sync()` freely without
  guarding for concurrency.

### Packaging

* `test` moved from `dependencies` to `dev_dependencies`. Avoids
  cross-version resolution conflicts in consumer apps (Flutter SDK
  pins of `matcher`/`test_api`, analyzer-version battles with
  `freezed`). Consumers that import `package:drift_sync_core/testing.dart`
  must add `test` to their own dev_dependencies.

## 0.1.0

First substantive release. Pre-1.0 — minor versions may break the API.

### Core

* Pure Dart core (no Flutter dependency).
* Three-phase reconciliation: upload local changes, reconcile client_ids,
  download server deltas via `synced_since` cursor.
* Typed persistence outcomes — handlers return `PersistOutcome<T>`
  carrying `persisted`, `skipped`, and `cursorAdvanceTo`.
* Sealed `EntitySyncState` (`NeverSynced`, `Healthy`) with default
  bridge implementations on `SynchronizerDb`.
* `Claimable` mixin marks handlers participating in client-id
  reconciliation. Handlers without it skip Phase 2.
* `skipClientIdReconciliation` constructor flag for UUID-only schemas
  that don't need Phase 2.

### Logging and crash reporting

* `SyncLogger` interface with single `log(level, message, ...)` method
  plus ergonomic `finest`/`debug`/`info`/`warning`/`severe`/`fatal`
  extension methods. `NoopSyncLogger` available as default.
* `SyncCrashReporter` interface — separate from logger — for routing
  unhandled errors to Crashlytics, Sentry, or any other crash service.
* Both passed via `DriftSynchronizer` constructor; logging defaults to
  noop, crash reporting is optional.

### Transport

* `RestSyncTypeHandler` mixin for HTTP transports. Catches
  `DioException` at the boundary and translates to typed semantic
  exceptions (`UnavailableException`, `NotFoundException`,
  `ConflictException`); other DioExceptions rethrow for the caller
  to crash-report.

### Testing

* Contract test suite at `package:drift_sync_core/testing.dart`
  for verifying consumer `SynchronizerDb` implementations satisfy
  the contract.
* 76 internal unit tests covering orchestrator phases, dependency
  manager, persist outcomes, and synchronizer DB bridges.

### Database contract

* `SynchronizerDb` is a plain mixin (not bound to `GeneratedDatabase`)
  with `transaction<R>({bool requireNew = false})` in the interface
  for testability.
* Default bridge implementations of `getEntitySyncState`,
  `updateEntitySyncState` based on `LocalSyncMetadata`.

### Breaking from pre-0.1 prototype

* Renamed `getlastSyncedAt` → `getLastSyncedAt`.
* Renamed `updateEnityLocalSyncMetadata` → `updateEntityLocalSyncMetadata`.
* Removed `ServerChange`, `getServerPendingChanges`,
  `getLatestServerChangeId` (inherited dead code from upstream).
* Replaced static `DriftSyncLogger` global with injected
  `SyncLogger` + `SyncCrashReporter`.
