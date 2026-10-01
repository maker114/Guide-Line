import '../core/store/store_diff.dart';

/// 「回到主页自动同步」的状态机（handoff #87c57e，2026-09-30 扩成六态）。
///
/// 为什么没有百分比：上传一次 HTTP PUT，中途拿不到任何有意义的进度 ——
/// 编一个"78%"会动的数，比一直转圈更不诚实。能兑现的承诺只有
/// 「在转 / 成了，这是提交号 / 这次没传，这是为什么」。
///
/// 六态分三档语气（右上角状态表，见 ADR-093）：
///   · 在忙 —— [running]（转圈缺口圆环）；
///   · 成了 —— [done]（绿胶囊 + 提交码，**停 2 秒自己按动画收场**）；
///   · **没传，但不是失败** —— [blocked]（黄：没有可上传的记录 / 云端有更新 /
///     两边都改过）与 [offline]（黄：GitHub 未连接）。这两种要用户看一眼再决定，
///     所以胶囊**常驻**到下一次同步成功，点开看原话；
///   · 真的失败了 —— [failed]（红：Token 不对、推送被拒……），同样常驻、可点开。
/// 红只留给"这次真的失败了"：把"这次没传"也画成红的，会让每一次没传都像出事了。
enum AutoSyncPhase {
  /// 没在同步，也没什么要说的（关着同步、两边一样、或者刚把胶囊收掉）。
  idle,

  /// 正在比对 / 正在上传 —— 标题栏右侧转一个缺口圆环。
  running,

  /// 传上去了：圆环拉长成绿色胶囊，并把提交号摆出来。
  done,

  /// 这次没传，但**不是失败**：黄色胶囊 + 一句短话（[AutoSyncState.label]）。
  blocked,

  /// 连不上 GitHub（需求⑤）：黄色胶囊，话是固定的「GitHub 未连接」。
  offline,

  /// 没能完成提交：胶囊变红，写「未同步」，点开看原因原话。
  failed,
}

/// 标题栏右侧那枚指示器读的东西。
class AutoSyncState {
  const AutoSyncState._({
    required this.phase,
    this.commitSha = '',
    this.label = '',
    this.reason = '',
  });

  const AutoSyncState.idle() : this._(phase: AutoSyncPhase.idle);

  const AutoSyncState.running() : this._(phase: AutoSyncPhase.running);

  /// [commitSha] 是那一次上传的提交码；老记账（1.8.5 及以前）没有码，允许空串，
  /// 界面按"未知"处理（写「已同步」）—— 但**不编一个码出来**。
  ///
  /// 停多久由控制器管：`done` 摆 2 秒后自己回到 [idle]（需求②），
  /// 所以这里只是一个"此刻该显示什么"的快照，不含计时。
  const AutoSyncState.done(String commitSha)
      : this._(phase: AutoSyncPhase.done, commitSha: commitSha);

  /// 这次没传，但不是失败：黄胶囊上写 [label]（要短，标题栏那一格很窄），
  /// [reason] 是点开看的**原话**。
  const AutoSyncState.blocked({required String label, required String reason})
      : this._(phase: AutoSyncPhase.blocked, label: label, reason: reason);

  /// 连不上 GitHub：话固定是「GitHub 未连接」（需求⑤要求的就是这一句），
  /// [reason] 里放实际拿到的那句错（网络原话），点开看。
  const AutoSyncState.offline(String reason)
      : this._(
          phase: AutoSyncPhase.offline,
          label: 'GitHub 未连接',
          reason: reason,
        );

  /// [reason] 是**原话**：直接把它摆给用户看，不改写成"同步失败"四个字 ——
  /// "两边都改过，没替你选"和"Token 不对"要用户做的事完全不同。
  const AutoSyncState.failed(String reason)
      : this._(phase: AutoSyncPhase.failed, label: '未同步', reason: reason);

  final AutoSyncPhase phase;

  final String commitSha;

  /// 胶囊上那句短话（黄/红态才有；`done` 摆的是提交码，见指示器）。
  final String label;

  final String reason;

  bool get isRunning => phase == AutoSyncPhase.running;

  /// 这一态有没有可点开的原因（黄/红态有，转圈与成功态没有）。
  bool get hasReason => reason.isNotEmpty;

  /// 有没有值得占着标题栏那一块的东西（静默态就完全不留痕）。
  bool get isVisible => phase != AutoSyncPhase.idle;

  @override
  bool operator ==(Object other) =>
      other is AutoSyncState &&
      other.phase == phase &&
      other.commitSha == commitSha &&
      other.label == label &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(phase, commitSha, label, reason);

  @override
  String toString() => 'AutoSyncState(${phase.name}, commitSha: $commitSha, '
      'label: $label, reason: $reason)';
}

/// 启动静默比对（需求⑤）攒下的一次"你要用哪一边"。
///
/// 它跟 [AutoSyncState] 不是一回事：那个说"右上角那一格现在画什么"，
/// 这个说"有一扇面板等着用户选"。分开的理由是**同一时刻两件事都要在**：
/// 面板摆在屏幕中央等选择，右上角那枚黄胶囊同时说明"现在跟云端对不上"。
class StartupSyncRequest {
  const StartupSyncRequest({
    required this.diff,
    required this.message,
    this.pullOnly = false,
  });

  /// 摆给用户看的差异（面板里那些行）。
  final StoreDiff diff;

  /// 面板顶上那句"为什么摆这个"。
  final String message;

  /// 这一扇**只给「使用云端数据」一个按钮**（ADR-095 第 ② 条）。
  ///
  /// 只有一种情形：**这台手机上 0 条活记录、云端有东西**。那时"用本机覆盖云端"
  /// 是被明令禁止的动作（读坏了也长成 0 条，不许拿空的盖掉远程），
  /// 面板上就不该放那个按钮 —— 放了就是先承诺、再拒绝。
  final bool pullOnly;

  @override
  String toString() =>
      'StartupSyncRequest(${diff.added}+/${diff.removed}-/${diff.modified}~, '
      '${pullOnly ? '只可拉取' : '可推可拉'}, $message)';
}
