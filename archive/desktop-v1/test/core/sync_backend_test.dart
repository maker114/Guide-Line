import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/models/enums.dart';
import 'package:guideline/sync/fake_backend.dart';
import 'package:guideline/sync/sync_backend.dart';

void main() {
  late FakeSyncBackend backend;

  setUp(() {
    backend = FakeSyncBackend();
  });

  TxRequest request({
    required String txId,
    required List<TxDoc> docs,
  }) =>
      TxRequest(txId: txId, docs: docs);

  TxDoc doc(DocName name, int baseVersion, String payload) =>
      TxDoc(name: name, baseVersion: baseVersion, payloadJson: payload);

  group('CAS 与幂等（与云函数语义一致）', () {
    test('首次提交建立 version = 1', () async {
      final outcome = await backend.commitTx(request(
        txId: 'tx-00000001',
        docs: <TxDoc>[doc(DocName.projects, 0, '{"items":[{"id":"p1"}]}')],
      ));

      expect(outcome, isA<Committed>());
      expect((outcome as Committed).versions[DocName.projects], 1);
      expect(backend.versionOf(DocName.projects), 1);
      expect(backend.payloadOf(DocName.projects), contains('p1'));
    });

    test('同一 txId 重放不再 +1（响应丢失后的重试）', () async {
      final payload = '{"items":[{"id":"p1"}]}';
      await backend.commitTx(request(txId: 'tx-00000002', docs: <TxDoc>[doc(DocName.projects, 0, payload)]));
      final replay = await backend.commitTx(request(txId: 'tx-00000002', docs: <TxDoc>[doc(DocName.projects, 0, payload)]));

      expect(replay, isA<Committed>());
      expect((replay as Committed).versions[DocName.projects], 1);
      expect(backend.versionOf(DocName.projects), 1);
    });

    test('陈旧 baseVersion → Conflict 并给出远端版本', () async {
      backend.seed(DocName.projects, version: 5, payloadJson: '{"items":[]}');

      final outcome = await backend.commitTx(request(
        txId: 'tx-00000003',
        docs: <TxDoc>[doc(DocName.projects, 4, '{"items":[]}')],
      ));

      expect(outcome, isA<Conflict>());
      expect((outcome as Conflict).remoteVersions[DocName.projects]!.version, 5);
      expect(backend.versionOf(DocName.projects), 5);
    });
  });

  group('跨文档事务', () {
    test('一次提交可以把两份文档同时 +1，且只调用一次 commitTx', () async {
      final outcome = await backend.commitTx(request(
        txId: 'tx-00000004',
        docs: <TxDoc>[
          doc(DocName.projects, 0, '{"items":[{"id":"p1"}]}'),
          doc(DocName.inspirations, 0, '{"items":[{"id":"i1"}]}'),
        ],
      ));

      expect(outcome, isA<Committed>());
      final versions = (outcome as Committed).versions;
      expect(versions[DocName.projects], 1);
      expect(versions[DocName.inspirations], 1);
      expect(backend.commitTxCallCount, 1, reason: '跨文档操作不得退化为两次提交');
    });

    test('任一份文档冲突则整笔都不写入', () async {
      backend.seed(DocName.projects, version: 3, payloadJson: '{"items":[{"id":"old"}]}');

      final outcome = await backend.commitTx(request(
        txId: 'tx-00000005',
        docs: <TxDoc>[
          doc(DocName.projects, 2, '{"items":[{"id":"new"}]}'),
          doc(DocName.inspirations, 0, '{"items":[{"id":"i1"}]}'),
        ],
      ));

      expect(outcome, isA<Conflict>());
      expect(backend.payloadOf(DocName.inspirations), isEmpty, reason: '半成品绝不能落库');
      expect(backend.versionOf(DocName.inspirations), 0);
    });
  });

  group('错误与探测', () {
    test('离线 → 可重试的网络错误', () async {
      backend.offline = true;
      try {
        await backend.getVersions();
        fail('应当抛出 BackendFailure');
      } on BackendFailure catch (failure) {
        expect(failure.code, BackendErrorCode.network);
        expect(failure.retryable, isTrue);
      }
    });

    test('凭证失效 → 不可重试，且配对码校验失败也走同一错误', () async {
      backend.unauthenticated = true;
      try {
        await backend.ensureAccount();
        fail('应当抛出 BackendFailure');
      } on BackendFailure catch (failure) {
        expect(failure.retryable, isFalse);
      }

      backend.unauthenticated = false;
      try {
        await backend.pairWithCode('123');
        fail('应当抛出 BackendFailure');
      } on BackendFailure catch (failure) {
        expect(failure.code, BackendErrorCode.unauthenticated);
      }
    });

    test('getVersions 只返回元数据，getDoc 返回整包', () async {
      backend.seed(DocName.tasks, version: 7, payloadJson: '{"items":[{"id":"t1"}]}');

      final versions = await backend.getVersions();
      expect(versions[DocName.tasks]!.version, 7);
      expect(versions[DocName.projects]!.version, 0);
      expect(backend.getVersionsCallCount, 1);

      final snapshot = await backend.getDoc(DocName.tasks);
      expect(snapshot.version, 7);
      expect(snapshot.payloadJson, contains('t1'));
      expect(snapshot.payloadJson, isNot(contains('version')));
    });

    test('forceConflict 可用于驱动冲突流程', () async {
      backend.forceConflict = true;
      final outcome = await backend.commitTx(request(
        txId: 'tx-00000006',
        docs: <TxDoc>[doc(DocName.events, 0, '{"items":[]}')],
      ));
      expect(outcome, isA<Conflict>());
      expect(backend.versionOf(DocName.events), 0);
      expect(backend.forceConflict, isFalse, reason: '只生效一次');
    });
  });
}
