import '../core/ids.dart';
import '../core/json/document.dart';
import '../core/models/entity.dart';
import '../core/models/enums.dart';
import '../core/store/local_state.dart';
import '../core/store/local_store.dart';
import '../core/store/pending_tx.dart';
import '../features/workspace.dart';
import 'sync_backend.dart';

/// 同步阶段（UI 直接消费 —— 设计文档 §2「状态可见」）。
enum SyncPhase { idle, replaying, pushing, pulling, conflict, error, offline }

class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.message,
    this.conflictDoc,
    this.lastSyncAt,
  });

  const SyncStatus.idle()
      : phase = SyncPhase.idle,
        message = null,
        conflictDoc = null,
        lastSyncAt = null;

  final SyncPhase phase;
  final String? message;

  /// 待用户裁决的冲突文档（`phase == conflict` 时有值）。
  final DocName? conflictDoc;

  final int? lastSyncAt;

  bool get isBusy =>
      phase == SyncPhase.replaying || phase == SyncPhase.pushing || phase == SyncPhase.pulling;

  String get label {
    switch (phase) {
      case SyncPhase.idle:
        return lastSyncAt == null ? '未同步' : '已同步';
      case SyncPhase.replaying:
        return '正在补发未完成事务…';
      case SyncPhase.pushing:
        return '正在上传…';
      case SyncPhase.pulling:
        return '正在拉取…';
      case SyncPhase.conflict:
        return '冲突待处理（${conflictDoc?.fileName ?? ''}）';
      case SyncPhase.offline:
        return '离线（本地已保存）';
      case SyncPhase.error:
        return '同步失败：${message ?? '未知错误'}';
    }
  }
}

/// 一次同步的结果。
class SyncReport {
  const SyncReport({
    required this.status,
    required this.pushed,
    required this.pulled,
    required this.replayedTx,
    required this.conflictDoc,
    this.errorCode,
  });

  final SyncStatus status;
  final List<DocName> pushed;
  final List<DocName> pulled;

  /// 本轮是否补发过待完成事务
  final bool replayedTx;
  final DocName? conflictDoc;
  final BackendErrorCode? errorCode;

  bool get ok => status.phase == SyncPhase.idle;
}

/// 首次同步的处置方案（设计文档 5.10 的判定表）。
enum ColdStartPlan {
  /// 两边都空 —— 直接建立基线
  bothEmpty,

  /// 本地空、云端有 —— 拉取覆盖
  pullFromCloud,

  /// 本地有、云端空 —— 全量推送
  pushToCloud,

  /// 两端都有内容且本地从未同步过 —— **不自动覆盖，交给用户选**
  needsUserChoice,
}

/// 冲突时用户的选择（设计文档 5.10）。
enum ConflictChoice {
  /// 以云端为准（本地未提交内容先落草稿）
  takeRemote,

  /// 以本地为准（用远端版本号作为新的 base 重推）
  keepLocal,
}

/// 同步引擎：把 `SyncBackend` 与本地 `Workspace` 接起来。
///
/// 固定顺序（设计文档 5.10）：
///   ① 补发 `pending_tx`（失败即终止本轮）
///   ② 推送脏文档（单文档也走一次事务提交）
///   ③ 拉取：先探测版本，再取整包
///   ④ 落盘 `sync_state`
///
/// **跨文档变更只发一次 `commitTx`** —— 这是 A3/ADR-050 的硬要求，由测试守护。
class SyncEngine {
  SyncEngine({
    required this.backend,
    required this.store,
    required this.workspace,
    SyncState? initialState,
  }) : _state = initialState ?? SyncState.initial;

  final SyncBackend backend;
  final LocalStore store;
  final Workspace workspace;

  SyncState _state;
  SyncStatus _status = const SyncStatus.idle();
  int? _lastSyncAt;

  SyncState get state => _state;

  SyncStatus get status => _status;

  // ---------------------------------------------------------------- 首次同步

  /// 判定首次同步该怎么走（**只读，不改数据**）。
  Future<ColdStartPlan> planColdStart() async {
    final versions = await backend.getVersions();
    final cloudEmpty = versions.values.every((m) => m.version == 0);
    final localEmpty = workspace.dirtyDocs.isEmpty && _localIsEmpty();
    final everSynced = _state.firstSyncDone;

    if (localEmpty && cloudEmpty) return ColdStartPlan.bothEmpty;
    if (localEmpty && !cloudEmpty) return ColdStartPlan.pullFromCloud;
    if (!localEmpty && cloudEmpty) return ColdStartPlan.pushToCloud;
    if (!everSynced) return ColdStartPlan.needsUserChoice;
    return ColdStartPlan.pushToCloud;
  }

  /// 本地是否没有任何用户数据（4 份文档都为空）。
  bool _localIsEmpty() {
    for (final name in DocName.values) {
      if (workspace.documentOf(name).items.any((e) => !e.deleted)) return false;
    }
    return true;
  }

  /// 用户选择「以云端为准」时的冷启动执行。
  Future<SyncReport> coldStartPull() async {
    _status = const SyncStatus(phase: SyncPhase.pulling);
    final pulled = await _pullAll(force: true);
    await _persistState(firstSyncDone: true);
    _status = _idleStatus();
    return SyncReport(
      status: _status,
      pushed: const <DocName>[],
      pulled: pulled,
      replayedTx: false,
      conflictDoc: null,
    );
  }

  // ---------------------------------------------------------------- 主流程

  Future<SyncReport> sync({bool force = false}) async {
    final pushed = <DocName>[];
    var replayedTx = false;

    try {
      // ⓪ 先确认会话（已配对则直接返回；失效时这里就会失败，避免后续一堆无谓请求）
      final account = await backend.ensureAccount();
      if (_state.accountId != account.accountId || _state.deviceId != account.deviceId) {
        _state = _state.copyWith(accountId: account.accountId, deviceId: account.deviceId);
        store.saveSyncState(_state);
      }

      // ① 补发未完成事务（跨文档必须一次提交）
      final tx = workspace.pendingTx;
      if (tx != null) {
        _status = const SyncStatus(phase: SyncPhase.replaying);
        final outcome = await _commitPendingTx(tx);
        if (outcome is Conflict) {
          final name = outcome.remoteVersions.keys.first;
          _status = SyncStatus(phase: SyncPhase.conflict, conflictDoc: name);
          return SyncReport(
            status: _status,
            pushed: pushed,
            pulled: const <DocName>[],
            replayedTx: false,
            conflictDoc: name,
          );
        }
        replayedTx = true;
        final committed = outcome as Committed;
        for (final entry in committed.versions.entries) {
          workspace.markSynced(entry.key, entry.value);
        }
        workspace.setPendingTx(null);
      }

      // ② 推送脏文档
      final dirty = workspace.dirtyDocs.toList(growable: false);
      if (dirty.isNotEmpty) {
        _status = const SyncStatus(phase: SyncPhase.pushing);
        for (final name in dirty) {
          final outcome = await _commitTx(_singleDocTx(name));
          if (outcome is Conflict) {
            _status = SyncStatus(phase: SyncPhase.conflict, conflictDoc: name);
            return SyncReport(
              status: _status,
              pushed: pushed,
              pulled: const <DocName>[],
              replayedTx: replayedTx,
              conflictDoc: name,
            );
          }
          workspace.markSynced(name, (outcome as Committed).versions[name]!);
          pushed.add(name);
        }
      }

      // ③ 拉取（先探测版本，再取整包）
      _status = const SyncStatus(phase: SyncPhase.pulling);
      final pulled = await _pullAll(force: force);

      await _persistState(firstSyncDone: true);
      _status = _idleStatus();
      return SyncReport(
        status: _status,
        pushed: pushed,
        pulled: pulled,
        replayedTx: replayedTx,
        conflictDoc: null,
      );
    } on BackendFailure catch (failure) {
      _status = SyncStatus(
        phase: failure.code == BackendErrorCode.network ? SyncPhase.offline : SyncPhase.error,
        message: failure.message,
      );
      return SyncReport(
        status: _status,
        pushed: pushed,
        pulled: const <DocName>[],
        replayedTx: replayedTx,
        conflictDoc: null,
        errorCode: failure.code,
      );
    }
  }

  // ---------------------------------------------------------------- 冲突处理

  /// 用户裁决冲突。
  Future<SyncReport> resolveConflict(DocName name, ConflictChoice choice) async {
    try {
      switch (choice) {
        case ConflictChoice.takeRemote:
          // 本地未推送内容先落草稿，再整体替换
          workspace.saveConflictDraft(name, Ids.nowMillis());
          final snapshot = await backend.getDoc(name);
          final issues = DecodeIssues();
          workspace.applyRemoteDocument(Document.fromPayloadJson(
            name: name,
            version: snapshot.version,
            updatedAt: snapshot.updatedAt,
            payloadJson: snapshot.payloadJson,
            issues: issues,
          ));
          _status = _idleStatus();
          return SyncReport(
            status: _status,
            pushed: const <DocName>[],
            pulled: <DocName>[name],
            replayedTx: false,
            conflictDoc: null,
          );
        case ConflictChoice.keepLocal:
          // 以云端版本号为新的 base 重推一次（等于放弃云端那一版）
          final versions = await backend.getVersions();
          final remoteVersion = versions[name]?.version ?? workspace.versionOf(name);
          workspace.applyRemoteDocument(workspace.documentOf(name).copyWith(version: remoteVersion));
          final outcome = await _commitTx(_singleDocTx(name));
          if (outcome is Conflict) {
            _status = SyncStatus(phase: SyncPhase.conflict, conflictDoc: name);
            return SyncReport(
              status: _status,
              pushed: const <DocName>[],
              pulled: const <DocName>[],
              replayedTx: false,
              conflictDoc: name,
            );
          }
          workspace.markSynced(name, (outcome as Committed).versions[name]!);
          _status = _idleStatus();
          return SyncReport(
            status: _status,
            pushed: <DocName>[name],
            pulled: const <DocName>[],
            replayedTx: false,
            conflictDoc: null,
          );
      }
    } on BackendFailure catch (failure) {
      _status = SyncStatus(phase: SyncPhase.error, message: failure.message);
      return SyncReport(
        status: _status,
        pushed: const <DocName>[],
        pulled: const <DocName>[],
        replayedTx: false,
        conflictDoc: name,
        errorCode: failure.code,
      );
    }
  }

  // ---------------------------------------------------------------- 内部

  TxDoc _singleDoc(DocName name) => TxDoc(
        name: name,
        baseVersion: workspace.versionOf(name),
        payloadJson: workspace.payloadJsonOf(name),
      );

  TxRequest _singleDocTx(DocName name) =>
      TxRequest(txId: Ids.uuidV4(), docs: <TxDoc>[_singleDoc(name)]);

  /// 提交一个已经构造好的事务请求。
  Future<CommitOutcome> _commitTx(TxRequest request) => backend.commitTx(request);

  /// 把待完成事务变成一次提交（**只发一次请求** —— 跨文档的硬要求）。
  Future<CommitOutcome> _commitPendingTx(PendingTx tx) {
    return backend.commitTx(TxRequest(
      txId: tx.txId,
      docs: <TxDoc>[
        for (final doc in tx.docs)
          TxDoc(
            name: doc.name,
            baseVersion: doc.baseVersion,
            payloadJson: workspace.payloadJsonOf(doc.name),
          ),
      ],
    ));
  }

  Future<List<DocName>> _pullAll({required bool force}) async {
    final versions = await backend.getVersions();
    final pulled = <DocName>[];

    for (final name in DocName.values) {
      final remote = versions[name]?.version ?? 0;
      final local = workspace.versionOf(name);
      if (!force && remote <= local) continue;

      final snapshot = await backend.getDoc(name);
      final issues = DecodeIssues();
      workspace.applyRemoteDocument(Document.fromPayloadJson(
        name: name,
        version: snapshot.version,
        updatedAt: snapshot.updatedAt,
        payloadJson: snapshot.payloadJson,
        issues: issues,
      ));
      pulled.add(name);
    }
    return pulled;
  }

  Future<void> _persistState({required bool firstSyncDone}) async {
    _lastSyncAt = Ids.nowMillis();
    _state = _state.copyWith(firstSyncDone: firstSyncDone, lastSyncAt: _lastSyncAt);
    store.saveSyncState(_state);
  }

  SyncStatus _idleStatus() => SyncStatus(phase: SyncPhase.idle, lastSyncAt: _lastSyncAt);
}
