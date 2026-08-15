import 'package:dio/dio.dart';
import 'package:drift_sync_core/drift_sync_core.dart';
import 'package:test/test.dart';

import '../_fakes.dart';

DioException _dio(int statusCode) {
  final options = RequestOptions(path: '/x');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response(requestOptions: options, statusCode: statusCode),
  );
}

void main() {
  late FakeSynchronizerDb db;
  late FakeHandler wallet;
  late TestSynchronizer sync;

  setUp(() {
    db = FakeSynchronizerDb();
    wallet = FakeHandler(entityType: 'wallet');
    sync = TestSynchronizer(
      appDatabase: db,
      typeHandlers: {wallet},
      dependencyManager: DefaultSyncDependencyManager(),
      requestAuthorizationService: FakeAuthService(),
      skipClientIdReconciliation: true,
    );
  });

  group('downloadServerChanges (non-paged)', () {
    test('empty server response records a successful attempt', () async {
      // No remote items.
      await sync.downloadServerChanges();
      expect(db.allMetadata['wallet']?.lastSyncedAt, isNull);
      expect(db.allMetadata['wallet']?.lastAttemptedAt, isNotNull);
      expect(db.allMetadata['wallet']?.lastError, isNull);
    });

    test('persists items and writes cursor as max lastSyncedAt', () async {
      final t1 = DateTime.utc(2026, 5, 1, 10);
      final t2 = DateTime.utc(2026, 5, 2, 10);

      wallet.remoteItems[1] =
          TestEntity(clientId: 'a', id: 1, lastSyncedAt: t1);
      wallet.remoteItems[2] =
          TestEntity(clientId: 'b', id: 2, lastSyncedAt: t2);

      await sync.downloadServerChanges();

      expect(wallet.localItems.keys, containsAll(['a', 'b']));
      expect(db.allMetadata['wallet']?.lastSyncedAt, t2,
          reason: 'cursor = max lastSyncedAt of persisted items');
    });

    test('skips items with empty clientId; cursor still advances past them',
        () async {
      final t1 = DateTime.utc(2026, 5, 1);
      final tUnclaimed = DateTime.utc(2030, 1, 1);

      wallet.remoteItems[1] =
          TestEntity(clientId: 'a', id: 1, lastSyncedAt: t1);
      wallet.remoteItems[2] =
          TestEntity(clientId: '', id: 2, lastSyncedAt: tUnclaimed);

      await sync.downloadServerChanges();

      expect(wallet.localItems.keys, ['a']);
      expect(db.allMetadata['wallet']?.lastSyncedAt, tUnclaimed,
          reason: 'unclaimed items were returned by the server and must '
              'advance the cursor, or they are re-fetched on every sync');
    });

    test('all-empty-clientId batch still advances the cursor', () async {
      // Pre-populate cursor.
      await db.updateEntityLocalSyncMetadata(
        entityType: 'wallet',
        lastSyncedAt: DateTime.utc(2025, 12, 1),
      );

      wallet.remoteItems[1] = TestEntity(
        clientId: '',
        id: 1,
        lastSyncedAt: DateTime.utc(2026, 5, 1),
      );

      await sync.downloadServerChanges();

      expect(db.allMetadata['wallet']?.lastSyncedAt, DateTime.utc(2026, 5, 1),
          reason: 'client-id assignment fetches unclaimed rows separately; '
              'holding the cursor back would re-fetch them forever');
    });

    test('full sync (no prior cursor) calls deleteLocalNotIn', () async {
      // Pre-populate local with a stale row not in remote.
      wallet.localItems['stale'] = const TestEntity(clientId: 'stale', id: 99);

      wallet.remoteItems[1] = TestEntity(
        clientId: 'a',
        id: 1,
        lastSyncedAt: DateTime.utc(2026, 5, 1),
      );

      await sync.downloadServerChanges();

      expect(wallet.deletedNotIn, contains('a'));
      expect(wallet.localItems.containsKey('stale'), isFalse,
          reason: 'stale row removed by deleteLocalNotIn during full sync');
    });

    test('incremental sync (prior cursor set) skips deleteLocalNotIn',
        () async {
      // Set a prior cursor — will trigger incremental path.
      await db.updateEntityLocalSyncMetadata(
        entityType: 'wallet',
        lastSyncedAt: DateTime.utc(2025, 1, 1),
      );

      wallet.localItems['stale'] = const TestEntity(clientId: 'stale', id: 99);
      wallet.remoteItems[1] = TestEntity(
        clientId: 'a',
        id: 1,
        lastSyncedAt: DateTime.utc(2026, 5, 1),
      );

      await sync.downloadServerChanges();

      expect(wallet.deletedNotIn, isEmpty,
          reason: 'incremental sync must NOT call deleteLocalNotIn');
      expect(wallet.localItems.containsKey('stale'), isTrue);
    });

    test('skipDownSync handler is skipped', () async {
      final skipper = _SkipDownSyncHandler();
      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {skipper},
        dependencyManager: DefaultSyncDependencyManager(),
        requestAuthorizationService: FakeAuthService(),
        skipClientIdReconciliation: true,
      );
      skipper.remoteItems[1] = TestEntity(
        clientId: 'a',
        id: 1,
        lastSyncedAt: DateTime.utc(2026, 5, 1),
      );

      await s.downloadServerChanges();
      expect(skipper.upsertedAll, isEmpty);
    });

    test('writes Healthy state with cursor after successful sync', () async {
      final t = DateTime.utc(2026, 5, 1);
      wallet.remoteItems[1] = TestEntity(clientId: 'a', id: 1, lastSyncedAt: t);

      await sync.downloadServerChanges();

      final state = await db.getEntitySyncState('wallet');
      expect(state, isA<Healthy>());
      expect((state as Healthy).cursor, t);
    });

    test('runs dependent handlers in dependency order', () async {
      final calls = <String>[];

      final w = _OrderRecordingHandler('wallet', calls);
      final t = _OrderRecordingHandler('transaction', calls);

      w.remoteItems[1] = TestEntity(
        clientId: 'w1',
        id: 1,
        lastSyncedAt: DateTime.utc(2026, 5, 1),
      );
      t.remoteItems[1] = TestEntity(
        clientId: 't1',
        id: 1,
        lastSyncedAt: DateTime.utc(2026, 5, 1),
      );

      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {w, t},
        dependencyManager: CustomDependencyManager({
          'transaction': {'wallet'},
        }),
        requestAuthorizationService: FakeAuthService(),
        skipClientIdReconciliation: true,
      );

      await s.downloadServerChanges();
      expect(calls, ['wallet:fetch', 'transaction:fetch']);
    });

    test('allows an opted-in dependent handler after a failure', () async {
      final dependency = FakeHandler(entityType: 'transaction');
      final dependent = FakeHandler(
        entityType: 'transfer',
        canSyncWithoutDependencies: true,
      );
      dependency.getAllRemoteThrows.add(Exception('failed dependency'));
      dependent.remoteItems[1] = TestEntity(
        clientId: 'transfer-1',
        id: 1,
        lastSyncedAt: DateTime.utc(2026, 5, 1),
      );

      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {dependency, dependent},
        dependencyManager: CustomDependencyManager({
          'transfer': {'transaction'},
        }),
        requestAuthorizationService: FakeAuthService(),
        skipClientIdReconciliation: true,
      );

      await s.downloadServerChanges();

      expect(dependent.localItems, contains('transfer-1'));
      expect(db.allMetadata['transaction']?.lastError, isNotNull);
    });
  });

  group('cursorRewind', () {
    test('sends the stored cursor unmodified when not configured', () async {
      final t = DateTime.utc(2026, 5, 1, 10, 0, 30);
      await db.updateEntityLocalSyncMetadata(
        entityType: 'wallet',
        lastSyncedAt: t,
      );

      await sync.downloadServerChanges();

      expect(wallet.syncedSinceCalls.single, t);
    });

    test('rewinds the cursor by the configured duration', () async {
      final t = DateTime.utc(2026, 5, 1, 10, 0, 30);
      await db.updateEntityLocalSyncMetadata(
        entityType: 'wallet',
        lastSyncedAt: t,
      );
      final rewindSync = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {wallet},
        dependencyManager: DefaultSyncDependencyManager(),
        requestAuthorizationService: FakeAuthService(),
        skipClientIdReconciliation: true,
        cursorRewind: const Duration(seconds: 1),
      );

      await rewindSync.downloadServerChanges();

      expect(wallet.syncedSinceCalls.single,
          t.subtract(const Duration(seconds: 1)));
    });

    test('full fetch (no cursor) still sends null', () async {
      await sync.downloadServerChanges();
      expect(wallet.syncedSinceCalls.single, isNull);
    });
  });

  group('parking (shouldPersistLocal)', () {
    test('deferred item is parked, others persist, cursor passes all',
        () async {
      final tOk = DateTime.utc(2026, 5, 1);
      final tBlocked = DateTime.utc(2026, 5, 2);

      wallet.remoteItems[1] =
          TestEntity(clientId: 'a', id: 1, lastSyncedAt: tOk);
      wallet.remoteItems[2] =
          TestEntity(clientId: 'b', id: 2, lastSyncedAt: tBlocked);
      wallet.persistLocalBlock = (e) => e.clientId == 'b';

      await sync.downloadServerChanges();

      expect(wallet.localItems.keys, ['a'],
          reason: 'blocked item must not be written');
      expect(db.parkedFor('wallet').keys, ['b']);
      expect(db.allMetadata['wallet']?.lastSyncedAt, tBlocked,
          reason: 'parked items must not hold the cursor back');
    });

    test('parked item persists and unparks once its dependency is met',
        () async {
      wallet.remoteItems[1] = const TestEntity(clientId: 'b', id: 2);
      wallet.persistLocalBlock = (e) => e.clientId == 'b';
      await sync.downloadServerChanges();
      expect(db.parkedFor('wallet').keys, ['b']);

      wallet.persistLocalBlock = null;
      wallet.remoteItems.clear();
      await sync.downloadServerChanges();

      expect(wallet.localItems.keys, ['b'],
          reason: 'retry must persist the parked copy');
      expect(db.parkedFor('wallet'), isEmpty);
    });

    test('still-blocked parked item stays parked without erroring', () async {
      wallet.remoteItems[1] = const TestEntity(clientId: 'b', id: 2);
      wallet.persistLocalBlock = (e) => e.clientId == 'b';
      await sync.downloadServerChanges();

      wallet.remoteItems.clear();
      await sync.downloadServerChanges();

      expect(wallet.localItems, isEmpty);
      expect(db.parkedFor('wallet').keys, ['b']);
    });

    test('persistable fresher copy drops the still-blocked parked one',
        () async {
      final tOld = DateTime.utc(2026, 5, 1);
      final tNew = DateTime.utc(2026, 5, 3);

      wallet.remoteItems[2] =
          TestEntity(clientId: 'b', id: 2, lastSyncedAt: tOld);
      // Only the OLD version has the unmet dependency (e.g. the new
      // version no longer references the missing parent).
      wallet.persistLocalBlock = (e) => e.lastSyncedAt == tOld;
      await sync.downloadServerChanges();
      expect(db.parkedFor('wallet').keys, ['b']);

      wallet.remoteItems[2] =
          TestEntity(clientId: 'b', id: 2, lastSyncedAt: tNew);
      await sync.downloadServerChanges();

      expect(wallet.localItems['b']?.lastSyncedAt, tNew);
      expect(db.parkedFor('wallet'), isEmpty,
          reason: 'no stale copy may remain to overwrite newer data later');
    });
  });

  group('downloadModelsWithNoClientIds', () {
    test('a local row with an empty clientId does not block assignment',
        () async {
      // Pre-guard bug shape: unclaimed server row also stored locally at ''.
      wallet.localItems[''] = const TestEntity(clientId: '', id: 103);
      wallet.remoteUnclaimed = [const TestEntity(clientId: '', id: 103)];

      await sync.downloadModelsWithNoClientIds();

      expect(wallet.putRemoteCalls.map((e) => e.clientId), ['gen_103'],
          reason: 'the empty-clientId row must not count as adopted');
    });

    test('a local row with a real clientId is skipped', () async {
      wallet.localItems['device:x'] =
          const TestEntity(clientId: 'device:x', id: 103);
      wallet.remoteUnclaimed = [const TestEntity(clientId: '', id: 103)];

      await sync.downloadModelsWithNoClientIds();

      expect(wallet.putRemoteCalls, isEmpty);
    });

    test('reconciliation pushes via claimClientId, not putRemote', () async {
      final claiming = ClaimRecordingHandler(entityType: 'wallet');
      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {claiming},
        dependencyManager: DefaultSyncDependencyManager(),
        requestAuthorizationService: FakeAuthService(),
      );
      claiming.remoteUnclaimed = [const TestEntity(clientId: '', id: 7)];

      await s.downloadModelsWithNoClientIds();

      expect(claiming.claimCalls, hasLength(1));
      expect(claiming.putRemoteCalls, isEmpty);
    });

    test('permanent claim failure does not block dependents', () async {
      final txn = FakeHandler(entityType: 'transaction');
      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {wallet, txn},
        dependencyManager: CustomDependencyManager({
          'transaction': {'wallet'},
        }),
        requestAuthorizationService: FakeAuthService(),
        classifyFailure: restFailureClassifier,
      );
      wallet.remoteUnclaimed = [const TestEntity(clientId: '', id: 5)];
      wallet.putRemoteThrows.add(_dio(422));

      await s.downloadModelsWithNoClientIds();

      expect(txn.noClientIdFetches, 1,
          reason: 'a permanently rejected claim cannot succeed later; '
              'it must not hold dependents hostage');
    });

    test('transient claim failure still blocks dependents', () async {
      final txn = FakeHandler(entityType: 'transaction');
      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {wallet, txn},
        dependencyManager: CustomDependencyManager({
          'transaction': {'wallet'},
        }),
        requestAuthorizationService: FakeAuthService(),
        classifyFailure: restFailureClassifier,
      );
      wallet.remoteUnclaimed = [const TestEntity(clientId: '', id: 5)];
      wallet.putRemoteThrows.add(_dio(500));

      await s.downloadModelsWithNoClientIds();

      expect(txn.noClientIdFetches, 0,
          reason: 'a retryable failure means the parent may still get its '
              'client id; dependents wait for the next cycle');
    });
  });
}

class _SkipDownSyncHandler extends FakeHandler {
  _SkipDownSyncHandler() : super(entityType: 'skip');

  @override
  bool get skipDownSync => true;
}

class _OrderRecordingHandler extends FakeHandler {
  _OrderRecordingHandler(String entityType, this.calls)
      : super(entityType: entityType);

  final List<String> calls;

  @override
  Future<List<TestEntity>> getAllRemote({
    DateTime? syncedSince,
    bool? noClientId,
  }) async {
    calls.add('$entityType:fetch');
    return super.getAllRemote(syncedSince: syncedSince, noClientId: noClientId);
  }
}
