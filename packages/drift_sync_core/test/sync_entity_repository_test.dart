import 'package:drift_sync_core/drift_sync_core.dart';
import 'package:test/test.dart';

import '_fakes.dart';

class TestRepo
    extends SyncEntityRepository<FakeSynchronizerDb, TestEntity, String, int> {
  const TestRepo({
    required super.syncHandler,
    required super.db,
    required super.requestAuthorizationService,
  });

  Future<TestEntity> saveNew(Future<TestEntity> Function() persistLocal) {
    return persistAndPost(persistLocal);
  }

  Future<void> removeInBackground(TestEntity entity) {
    return persistAndDelete(entity);
  }
}

void main() {
  late FakeSynchronizerDb db;
  late FakeHandler handler;
  late FakeAuthService auth;
  late TestRepo repo;

  setUp(() {
    db = FakeSynchronizerDb();
    handler = FakeHandler(entityType: 'test')..db = db;
    auth = FakeAuthService();
    repo = TestRepo(
      syncHandler: handler,
      db: db,
      requestAuthorizationService: auth,
    );
  });

  PendingLocalChange? pendingFor(String clientId) {
    for (final c in db.allPending) {
      if (c.entityId == clientId) return c;
    }
    return null;
  }

  group('post', () {
    test('commits the local write and outbox entry together', () async {
      auth.authorized = false;
      var localWriteWasTransactional = false;

      final entity = await repo.saveNew(() async {
        localWriteWasTransactional = db.inTransaction;
        return const TestEntity(clientId: 'a');
      });

      expect(entity.clientId, 'a');
      expect(localWriteWasTransactional, isTrue);
      expect(pendingFor('a'), isNotNull);
    });

    test('successful remote create leaves no pending change', () async {
      final (created, ds) = await repo.post(const TestEntity(clientId: 'a'));

      expect(ds, DataDestination.both);
      expect(created.id, isNotNull);
      expect(db.allPending, isEmpty);
      expect(handler.localItems['a']?.id, created.id);
    });

    test('server rejection keeps the pending change with the error', () async {
      handler.putRemoteThrows.add(Exception('422 validation failed'));

      final (created, ds) = await repo.post(const TestEntity(clientId: 'a'));

      expect(ds, DataDestination.local);
      expect(created.id, isNull);
      final pending = pendingFor('a');
      expect(pending, isNotNull);
      expect(pending!.error, contains('422'));
      expect(pending.attemptCount, 1);
      expect(pending.deleted, isFalse);
    });

    test('server rejection does not rethrow', () async {
      handler.putRemoteThrows.add(StateError('boom'));

      await expectLater(
        repo.post(const TestEntity(clientId: 'a')),
        completes,
      );
    });

    test('network unavailable enqueues without an error', () async {
      handler.putRemoteThrows.add(UnavailableException());

      final (_, ds) = await repo.post(const TestEntity(clientId: 'a'));

      expect(ds, DataDestination.local);
      final pending = pendingFor('a');
      expect(pending, isNotNull);
      expect(pending!.error, isNull);
      expect(pending.attemptCount, 0);
    });

    test('unauthenticated enqueues without attempting remote', () async {
      auth.authorized = false;

      final (_, ds) = await repo.post(const TestEntity(clientId: 'a'));

      expect(ds, DataDestination.local);
      expect(handler.putRemoteCalls, isEmpty);
      expect(pendingFor('a'), isNotNull);
    });
  });

  group('put', () {
    test('successful remote update leaves no pending change', () async {
      final (_, ds) = await repo.put(const TestEntity(clientId: 'a', id: 7));

      expect(ds, DataDestination.both);
      expect(db.allPending, isEmpty);
    });

    test('server rejection keeps the pending change with the error', () async {
      handler.putRemoteThrows.add(Exception('500 server error'));

      final (_, ds) = await repo.put(const TestEntity(clientId: 'a', id: 7));

      expect(ds, DataDestination.local);
      final pending = pendingFor('a');
      expect(pending, isNotNull);
      expect(pending!.error, contains('500'));
    });

    test('entity without server id enqueues without attempting remote',
        () async {
      final (_, ds) = await repo.put(const TestEntity(clientId: 'a'));

      expect(ds, DataDestination.local);
      expect(handler.putRemoteCalls, isEmpty);
      expect(pendingFor('a'), isNotNull);
    });
  });

  group('delete', () {
    test('successful remote delete leaves no pending change', () async {
      handler.localItems['a'] = const TestEntity(clientId: 'a', id: 7);

      final ds = await repo.delete(const TestEntity(clientId: 'a', id: 7));

      expect(ds, DataDestination.both);
      expect(db.allPending, isEmpty);
      expect(handler.localItems, isEmpty);
      expect(handler.deletedRemote, hasLength(1));
    });

    test('server rejection keeps the delete change with the error', () async {
      handler.deleteRemoteThrows.add(Exception('409 conflict'));

      final ds = await repo.delete(const TestEntity(clientId: 'a', id: 7));

      expect(ds, DataDestination.local);
      final pending = pendingFor('a');
      expect(pending, isNotNull);
      expect(pending!.deleted, isTrue);
      expect(pending.error, contains('409'));
    });

    test('never-synced entity concludes immediately without remote call',
        () async {
      handler.localItems['a'] = const TestEntity(clientId: 'a');

      final ds = await repo.delete(const TestEntity(clientId: 'a'));

      expect(ds, DataDestination.local);
      expect(db.allPending, isEmpty);
      expect(handler.deletedRemote, isEmpty);
      expect(handler.localItems, isEmpty);
    });

    test('delete change replaces a queued put for the same entity', () async {
      handler.putRemoteThrows.add(Exception('422'));
      await repo.post(const TestEntity(clientId: 'a'));
      expect(pendingFor('a')!.deleted, isFalse);

      await repo.delete(const TestEntity(clientId: 'a'));

      expect(db.allPending, isEmpty,
          reason: 'never-synced delete concludes and removes the queued put');
    });

    test('unauthenticated delete of synced entity stays queued', () async {
      auth.authorized = false;

      final ds = await repo.delete(const TestEntity(clientId: 'a', id: 7));

      expect(ds, DataDestination.local);
      final pending = pendingFor('a');
      expect(pending, isNotNull);
      expect(pending!.deleted, isTrue);
      expect(pending.error, isNull);
      expect(handler.deletedRemote, isEmpty);
    });
  });

  group('persistAndDelete', () {
    test('returns before the remote call is made', () async {
      handler.localItems['a'] = const TestEntity(clientId: 'a', id: 7);

      await repo.removeInBackground(const TestEntity(clientId: 'a', id: 7));

      expect(handler.localItems, isEmpty,
          reason: 'local deletion is durable before returning');
      expect(pendingFor('a'), isNotNull,
          reason: 'outbox entry is durable before returning');
      expect(handler.deletedRemote, isEmpty,
          reason: 'caller is not held for the network round trip');
    });

    test('commits the local delete and outbox entry together', () async {
      handler.localItems['a'] = const TestEntity(clientId: 'a', id: 7);

      await repo.removeInBackground(const TestEntity(clientId: 'a', id: 7));
      await pumpEventQueue();

      expect(handler.deleteLocalWasTransactional, isTrue);
    });

    test('concludes the pending change once the remote delete lands', () async {
      handler.localItems['a'] = const TestEntity(clientId: 'a', id: 7);

      await repo.removeInBackground(const TestEntity(clientId: 'a', id: 7));
      await pumpEventQueue();

      expect(handler.deletedRemote, hasLength(1));
      expect(db.allPending, isEmpty);
    });

    test('server rejection records the error on the queued change', () async {
      handler.deleteRemoteThrows.add(Exception('409 conflict'));

      await repo.removeInBackground(const TestEntity(clientId: 'a', id: 7));
      await pumpEventQueue();

      final pending = pendingFor('a');
      expect(pending, isNotNull);
      expect(pending!.deleted, isTrue);
      expect(pending.error, contains('409'));
    });

    test('never-synced entity concludes immediately without a remote call',
        () async {
      handler.localItems['a'] = const TestEntity(clientId: 'a');

      await repo.removeInBackground(const TestEntity(clientId: 'a'));
      await pumpEventQueue();

      expect(db.allPending, isEmpty);
      expect(handler.deletedRemote, isEmpty);
      expect(handler.localItems, isEmpty);
    });
  });
}
