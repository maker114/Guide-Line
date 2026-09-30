/// 「回到主页自动同步」的四态状态机（handoff #87c57e）。
///
/// 为什么只有四个态、没有百分比：上传一次 HTTP PUT，中途拿不到任何有意义的进度 ——
/// 编一个"78%"会动的数，比一直转圈更不诚实。能兑现的承诺只有
/// 「在转 / 成了，这是提交号 / 没成，这是原因」。
enum AutoSyncPhase {
  /// 没在同步，也没什么要说的（关着同步、或者刚比对完发现没变化）。
  idle,

  /// 正在比对 / 正在上传 —— 标题栏右侧转一个缺口圆环。
  running,

  /// 传上去了：圆环向左拉伸成绿色胶囊，并把提交号摆出来。
  done,

  /// 没能完成提交：胶囊变红，点开看原因原话。
  failed,
}

/// 标题栏右侧那枚指示器读的东西。
class AutoSyncState {
  const AutoSyncState._({
    required this.phase,
    this.commitSha = '',
    this.reason = '',
  });

  const AutoSyncState.idle() : this._(phase: AutoSyncPhase.idle);

  const AutoSyncState.running() : this._(phase: AutoSyncPhase.running);

  /// [commitSha] 是那一次上传的提交码；老记账（1.8.5 及以前）没有码，允许空串，
  /// 界面按"未知"处理 —— 但**不编一个码出来**。
  const AutoSyncState.done(String commitSha)
      : this._(phase: AutoSyncPhase.done, commitSha: commitSha);

  /// [reason] 是**原话**：直接把它摆给用户看，不改写成"同步失败"四个字 ——
  /// "两边都改过，没替你选"和"Token 不对"要用户做的事完全不同。
  const AutoSyncState.failed(String reason)
      : this._(phase: AutoSyncPhase.failed, reason: reason);

  final AutoSyncPhase phase;

  final String commitSha;

  final String reason;

  bool get isRunning => phase == AutoSyncPhase.running;

  /// 有没有值得占着标题栏那一块的东西（静默态就完全不留痕）。
  bool get isVisible => phase != AutoSyncPhase.idle;

  @override
  bool operator ==(Object other) =>
      other is AutoSyncState &&
      other.phase == phase &&
      other.commitSha == commitSha &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(phase, commitSha, reason);

  @override
  String toString() =>
      'AutoSyncState(${phase.name}, commitSha: $commitSha, reason: $reason)';
}
