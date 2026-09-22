import '../core/models/enums.dart';
import 'sync_backend.dart';

/// 内存假后端（M5 用）：用于在没有 CloudBase 环境时把同步层完整跑通。
///
/// 它**忠实复刻**云函数的语义，而不是"随便成功"：
///   · CAS：`baseVersion` 与当前版本不等 → [Conflict]；
///   · 事务：任何一份文档冲突 → **整笔不写**；
///   · 幂等：同一 `txId` 重放 → 返回原版本，不重复 +1；
///   · 计数：`commitTxCallCount` / `getDocCallCount` 供测试断言
///     「跨文档操作只调用一次 commitTx」。
class FakeSyncBackend implements SyncBackend {
  FakeSyncBackend({
    this.latency = Duration.zero,
    this.accountId = 'fake-account-0001',
    this.deviceId = 'fake-device-0001',
  });

  final Duration latency;

  String accountId;
  String deviceId;

  /// 模拟离线：所有调用抛出可重试的网络错误。
  bool offline = false;

  /// 模拟"下次提交必定冲突"（用于冲突流程测试）。
  bool forceConflict = false;

  /// 模拟"凭证失效"。
  bool unauthenticated = false;

  int commitTxCallCount = 0;

  int getDocCallCount = 0;

  int getVersionsCallCount = 0;

  final Map<DocName, _FakeDoc> _docs = <DocName, _FakeDoc>{};

  @override
  Future<Account> ensureAccount() async {
    await _tick();
    if (unauthenticated) {
      throw const BackendFailure(BackendErrorCode.unauthenticated, '会话已失效');
    }
    return Account(accountId: accountId, deviceId: deviceId);
  }

  @override
  Future<Account> pairWithCode(String pairingCode) async {
    await _tick();
    if (unauthenticated) {
      throw const BackendFailure(BackendErrorCode.unauthenticated, '会话已失效');
    }
    if (pairingCode.length != 6) {
      throw const BackendFailure(BackendErrorCode.unauthenticated, '配对码无效或已过期');
    }
    return Account(accountId: accountId, deviceId: deviceId);
  }

  @override
  Future<Map<DocName, DocMeta>> getVersions() async {
    await _tick();
    getVersionsCallCount += 1;
    final out = <DocName, DocMeta>{};
    for (final name in DocName.values) {
      final doc = _docs[name];
      out[name] = DocMeta(
        version: doc?.version ?? 0,
        updatedAt: doc?.updatedAt,
      );
    }
    return out;
  }

  @override
  Future<DocSnapshot> getDoc(DocName name) async {
    await _tick();
    getDocCallCount += 1;
    final doc = _docs[name];
    return DocSnapshot(
      name: name,
      version: doc?.version ?? 0,
      updatedAt: doc?.updatedAt,
      payloadJson: doc?.payloadJson ?? '{"items":[]}',
    );
  }

  @override
  Future<CommitOutcome> commitTx(TxRequest request) async {
    await _tick();
    commitTxCallCount += 1;
    if (forceConflict) {
      forceConflict = false;
      return Conflict(<DocName, DocMeta>{
        for (final doc in request.docs)
          doc.name: DocMeta(version: (_docs[doc.name]?.version ?? 0) + 1, updatedAt: null),
      });
    }

    // 先全读校验（模拟事务内的 CAS 检查）
    for (final doc in request.docs) {
      final current = _docs[doc.name];
      final currentVersion = current?.version ?? 0;
      final alreadyByThisTx = current != null && current.lastTxId == request.txId && currentVersion != doc.baseVersion;
      if (currentVersion != doc.baseVersion && !alreadyByThisTx) {
        return Conflict(<DocName, DocMeta>{
          for (final d in request.docs)
            d.name: DocMeta(version: _docs[d.name]?.version ?? 0, updatedAt: _docs[d.name]?.updatedAt),
        });
      }
    }

    // 后全写
    final versions = <DocName, int>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final doc in request.docs) {
      final current = _docs[doc.name];
      final currentVersion = current?.version ?? 0;
      final alreadyWritten = current != null && current.lastTxId == request.txId && currentVersion != doc.baseVersion;
      if (alreadyWritten) {
        versions[doc.name] = currentVersion;
        continue;
      }
      final next = currentVersion + 1;
      _docs[doc.name] = _FakeDoc(version: next, updatedAt: now, lastTxId: request.txId, payloadJson: doc.payloadJson);
      versions[doc.name] = next;
    }
    return Committed(versions);
  }

  /// 直接铺一份文档（模拟"另一端改了数据"）。
  void seed(DocName name, {required int version, required String payloadJson, String? lastTxId}) {
    _docs[name] = _FakeDoc(
      version: version,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      lastTxId: lastTxId,
      payloadJson: payloadJson,
    );
  }

  /// 便于断言"云端到底存了什么"。
  String payloadOf(DocName name) => _docs[name]?.payloadJson ?? '';

  int versionOf(DocName name) => _docs[name]?.version ?? 0;

  Future<void> _tick() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (offline) {
      throw const BackendFailure(BackendErrorCode.network, '网络不可用');
    }
  }
}

class _FakeDoc {
  _FakeDoc({
    required this.version,
    required this.updatedAt,
    required this.lastTxId,
    required this.payloadJson,
  });

  final int version;
  final int? updatedAt;
  final String? lastTxId;
  final String payloadJson;
}
