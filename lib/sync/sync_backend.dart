import '../core/models/enums.dart';

/// 同步后端接口（《同步与云函数契约》§2）。
///
/// **硬约束**：
///   1. `payload` 以**原始 JSON 字符串**穿过接口层 —— 序列化只由 `lib/core` 负责，
///      避免二次编解码改变字节形态；
///   2. CloudBase SDK 类型**不得**出现在这里的签名中（ADR-019 / ADR-064）；
///   3. 只有 5 个方法；新增能力必须先改契约。

/// 版本探测结果。
class DocMeta {
  const DocMeta({required this.version, required this.updatedAt});

  final int version;
  final int? updatedAt;

  @override
  String toString() => 'DocMeta(v$version, $updatedAt)';
}

/// 整包读取结果。
class DocSnapshot {
  const DocSnapshot({
    required this.name,
    required this.version,
    required this.updatedAt,
    required this.payloadJson,
  });

  final DocName name;
  final int version;
  final int? updatedAt;
  final String payloadJson;
}

/// 一次事务中的单份文档。
class TxDoc {
  const TxDoc({required this.name, required this.baseVersion, required this.payloadJson});

  final DocName name;
  final int baseVersion;
  final String payloadJson;
}

/// 一次事务提交请求（跨文档变更必须一次给全）。
class TxRequest {
  const TxRequest({required this.txId, required this.docs});

  final String txId;
  final List<TxDoc> docs;

  bool get isCrossDocument => docs.length > 1;
}

/// 提交结果（不抛异常，便于上层做 UI 决策）。
abstract class CommitOutcome {
  const CommitOutcome();
}

class Committed extends CommitOutcome {
  const Committed(this.versions);

  final Map<DocName, int> versions;
}

class Conflict extends CommitOutcome {
  const Conflict(this.remoteVersions);

  final Map<DocName, DocMeta> remoteVersions;
}

enum BackendErrorCode {
  unauthenticated,
  forbidden,
  conflict,
  notFound,
  rateLimited,
  invalid,
  network,
  internal,
}

class BackendFailure implements Exception {
  const BackendFailure(this.code, this.message, {this.retryAfterSeconds});

  final BackendErrorCode code;
  final String message;
  final int? retryAfterSeconds;

  /// 是否值得重试（网络类与限频值得，凭证类不值得）。
  bool get retryable =>
      code == BackendErrorCode.network ||
      code == BackendErrorCode.rateLimited ||
      code == BackendErrorCode.internal;

  @override
  String toString() => 'BackendFailure(${code.name}: $message)';
}

/// 账号会话。
class Account {
  const Account({required this.accountId, required this.deviceId});

  final String accountId;
  final String deviceId;
}

abstract class SyncBackend {
  /// 建立 / 恢复会话（已登录则直接返回）。
  Future<Account> ensureAccount();

  /// 次端配对：用一次性配对码换取同一 accountId 的会话。
  Future<Account> pairWithCode(String pairingCode);

  /// 只读元数据 —— **轮询只能调用它**。
  Future<Map<DocName, DocMeta>> getVersions();

  /// 读取整包 payload。
  Future<DocSnapshot> getDoc(DocName name);

  /// 唯一写入口：CAS + 写入 + version+1 + lastTxId。
  Future<CommitOutcome> commitTx(TxRequest request);
}
