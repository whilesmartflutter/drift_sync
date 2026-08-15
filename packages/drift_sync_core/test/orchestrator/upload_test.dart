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

PendingLocalChange _put({
  required String entityType,
  required String clientId,
  int? id,
  String rev = '1',
}) {
  return PendingLocalChange.put(
    entityType: entityType,
    entityId: clientId,
    entityRev: rev,
    entityData: TestEntity(clientId: clientId, id: id, rev: rev).toJson(),
  );
}

PendingLocalChange _delete({
  required String entityType,
  required String clientId,
  int? id,
}) {
  return PendingLocalChange.delete(
    entityType: entityType,
    entityId: clientId,
    entityRev: '1',
    data: TestEntity(clientId: clientId, id: id).toJson(),
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

  group('uploadLocalChanges', () {
    test('returns true when there are no pending changes', () async {
      final concluded = await sync.uploadLocalChanges();
      expect(concluded, isTrue);
    });

    test('returns false when canSync is false', () async {
      final auth = FakeAuthService()..authorized = false;
      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {wallet},
        dependencyManager: DefaultSyncDependencyManager(),
        requestAuthorizationService: auth,
        skipClientIdReconciliation: true,
      );
      expect(await s.uploadLocalChanges(), isFalse);
    });

    test('uploads put change and concludes it', () async {
      await db.insertLocalChange(_put(
        entityType: 'wallet',
        clientId: 'w1',
        id: 1,
      ));

      await sync.uploadLocalChanges();

      expect(wallet.putRemoteCalls, hasLength(1));
      expect(wallet.putRemoteCalls.single.clientId, 'w1');
      expect(db.allPending, isEmpty,
          reason: 'pending change must be removed on success');
    });

    test('uploads delete change with non-null serverId', () async {
      await db.insertLocalChange(_delete(
        entityType: 'wallet',
        clientId: 'w1',
        id: 42,
      ));

      await sync.uploadLocalChanges();

      expect(wallet.deletedRemote, hasLength(1));
      expect(wallet.deletedRemote.single.id, 42);
      expect(db.allPending, isEmpty);
    });

    test('skips deleteRemote when serverId is null but still concludes',
        () async {
      await db.insertLocalChange(_delete(
        entityType: 'wallet',
        clientId: 'w1',
        id: null,
      ));

      await sync.uploadLocalChanges();

      expect(wallet.deletedRemote, isEmpty,
          reason: 'no remote delete when serverId is null');
      expect(db.allPending, isEmpty,
          reason: 'pending change still concluded (nothing to retry)');
    });

    test(
        'records a transient dependency-pending error when '
        'shouldPersistRemote refuses', () async {
      wallet.shouldPersistRemoteResult = false;
      await db.insertLocalChange(_put(
        entityType: 'wallet',
        clientId: 'w1',
      ));

      await sync.uploadLocalChanges();

      expect(wallet.putRemoteCalls, isEmpty);
      final row = db.allPending.single;
      expect(row.error, contains('dependencies'));
      expect(row.quarantinedAt, isNull,
          reason: 'transient — retried once dependencies sync');
      expect(row.attemptCount, 1);
    });

    test('quarantines an unparseable queued payload on the first attempt',
        () async {
      await db.insertLocalChange(PendingLocalChange.put(
        entityType: 'wallet',
        entityId: 'w-bad',
        entityRev: '1',
        entityData: const {'clientId': 123},
      ));

      await sync.uploadLocalChanges();

      expect(wallet.putRemoteCalls, isEmpty);
      final row = db.allPending.single;
      expect(row.error, contains('UnmarshalException'));
      expect(row.quarantinedAt, isNotNull,
          reason: 'an immutable payload that cannot parse never will');
    });

    test('returns false on UnavailableException, leaves pending intact',
        () async {
      wallet.putRemoteThrows.add(const UnavailableException());
      await db.insertLocalChange(_put(
        entityType: 'wallet',
        clientId: 'w1',
        id: 1,
      ));

      final concluded = await sync.uploadLocalChanges();
      expect(concluded, isFalse);
      expect(db.allPending, hasLength(1),
          reason: 'pending change preserved on transport failure');
    });

    test('non-Unavailable error concludes pending change with error', () async {
      wallet.putRemoteThrows.add(Exception('500 server fart'));
      await db.insertLocalChange(_put(
        entityType: 'wallet',
        clientId: 'w1',
        id: 1,
      ));

      final concluded = await sync.uploadLocalChanges();
      expect(concluded, isTrue,
          reason: 'continues processing after non-transport error');
      // Pending change concluded with error → still in store but with error.
      final remaining = db.allPending.where((c) => c.entityId == 'w1').toList();
      expect(remaining, hasLength(1));
      expect(remaining.single.error, contains('500 server fart'));
    });

    test('continues processing remaining changes after one fails', () async {
      wallet.putRemoteThrows.add(Exception('boom on w1'));
      await db.insertLocalChange(_put(
        entityType: 'wallet',
        clientId: 'w1',
        id: 1,
      ));
      // give w2 a slightly later createMoment
      await Future.delayed(const Duration(milliseconds: 1));
      await db.insertLocalChange(_put(
        entityType: 'wallet',
        clientId: 'w2',
        id: 2,
      ));

      await sync.uploadLocalChanges();

      expect(wallet.putRemoteCalls.length, 2);
      expect(
          wallet.putRemoteCalls.map((e) => e.clientId).toList(), ['w1', 'w2']);
    });

    test('local write + conclude commit inside one transaction', () async {
      await db.insertLocalChange(_put(
        entityType: 'wallet',
        clientId: 'w1',
        id: 1,
      ));
      bool sawTransactionDuringUpsert = false;
      // Spy on persistLocal to verify the tx is active when called.
      final spyHandler = _SpyOnPersist(
        wallet,
        onUpsert: () {
          sawTransactionDuringUpsert = db.inTransaction;
        },
      );
      final s = TestSynchronizer(
        appDatabase: db,
        typeHandlers: {spyHandler},
        dependencyManager: DefaultSyncDependencyManager(),
        requestAuthorizationService: FakeAuthService(),
        skipClientIdReconciliation: true,
      );

      await s.uploadLocalChanges();
      expect(sawTransactionDuringUpsert, isTrue,
          reason: 'persistLocal must run inside a transaction');
    });
  });

  group('failure classification on upload', () {
    TestSynchronizer restSync({int budget = 3}) => TestSynchronizer(
          appDatabase: db,
          typeHandlers: {wallet},
          dependencyManager: DefaultSyncDependencyManager(),
          requestAuthorizationService: FakeAuthService(),
          skipClientIdReconciliation: true,
          classifyFailure: restFailureClassifier,
          unknownFailureRetryBudget: budget,
        );

    test('permanent failure (4xx) quarantines the change', () async {
      await db.insertLocalChange(_put(entityType: 'wallet', clientId: 'a'));
      wallet.putRemoteThrows.add(_dio(422));

      await restSync().uploadLocalChanges();

      final row = db.allPending.single;
      expect(row.quarantinedAt, isNotNull);
      expect(row.attemptCount, 1);
    });

    test('transient failure (5xx) stays retryable', () async {
      await db.insertLocalChange(_put(entityType: 'wallet', clientId: 'a'));
      wallet.putRemoteThrows.add(_dio(500));

      await restSync().uploadLocalChanges();

      final row = db.allPending.single;
      expect(row.quarantinedAt, isNull);
      expect(row.attemptCount, 1);
    });

    test('unknown failure escalates once the retry budget is spent', () async {
      await db.insertLocalChange(
        _put(entityType: 'wallet', clientId: 'a').copyWith(attemptCount: 2),
      );
      wallet.putRemoteThrows.add(Exception('boom'));

      await restSync(budget: 3).uploadLocalChanges();

      expect(db.allPending.single.quarantinedAt, isNotNull,
          reason: 'attempt 3 of budget 3 must escalate');
    });

    test('unknown failure below the budget stays retryable', () async {
      await db.insertLocalChange(_put(entityType: 'wallet', clientId: 'a'));
      wallet.putRemoteThrows.add(Exception('boom'));

      await restSync(budget: 3).uploadLocalChanges();

      expect(db.allPending.single.quarantinedAt, isNull);
    });
  });
}

/// Spy that wraps a handler and runs a callback when persist fires.
class _SpyOnPersist extends FakeHandler {
  _SpyOnPersist(FakeHandler base, {required this.onUpsert})
      : super(entityType: base.entityType);

  final void Function() onUpsert;

  @override
  Future<PersistOutcome<TestEntity>> persistOne(
    TestEntity entity,
    SyncCommitTx tx,
  ) {
    onUpsert();
    return super.persistOne(entity, tx);
  }
}
