import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/auto_sync_state.dart';
import '../../core/store/github_sync.dart';
import '../../core/store/store_diff.dart';
import 'store_diff_panel.dart';

/// **同步那些"要你看一眼"的弹窗**：两个外壳共用这一份（ADR-095 第 ⑥ 条）。
///
/// 为什么要有它：这三扇东西（本次改动的差异面板、开机比对的二选一面板、
/// "连不上 GitHub"的警告）原来都长在手机外壳 `_AppShellState` 里 ——
/// 控制器摆出 `pendingAutoPushDiff` / `pendingStartupSync` /
/// `pendingStartupOfflineWarning`，外壳监听到了就来问。
///
/// 加了电脑端之后就有了**两个外壳**：桌面外壳只会调 `startupSyncCheck()`，
/// 却没人监听这三个待办 —— 于是电脑上"开机比对"跑了、比出两边对不上，
/// 右上角挂着黄胶囊说"两边都改过"，**面板却永远不出现**，用户想选都没地方选；
/// 「连不上」那声警告同样没人弹，连"今天弹过"也没人记账。
///
/// 所以把它提成一个挂在两边的组件，而不是在两个外壳里各抄一遍：
/// 抄一遍就是两份会各自漂的实现（改一处文案、另一处不动）。
/// 判据只有一条 —— **谁的 `build` 里挂了它，谁就负责把这三扇弹出来**。
///
/// 用法：套在外壳 `build` 返回的那棵树外面，把**外壳自己的 `context`**
/// 传进来（弹窗要挂在这个 Navigator 上、跟着它在屏幕上居中）。
class AutoSyncPanels extends StatefulWidget {
  const AutoSyncPanels({
    super.key,
    required this.app,
    required this.shellContext,
    required this.child,
  });

  final AppController app;

  /// 外壳的 `BuildContext`（用来弹面板；桌面端与手机端各自传自己的）。
  ///
  /// 不用 `context` 这个名字：`State.build` 里那个 `context` 是**本组件**的，
  /// 两者混在一处最容易在弹窗挂错 Navigator 时看不出来。
  final BuildContext shellContext;

  final Widget child;

  @override
  State<AutoSyncPanels> createState() => _AutoSyncPanelsState();
}

class _AutoSyncPanelsState extends State<AutoSyncPanels> {
  /// 此刻开着几扇（同一时刻只留一扇：重复弹两张会把用户按在确认键上）。
  int _sheetsOpen = 0;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onAppChanged);
    // 挂上来的这一刻也要看一眼**已经摆着的**待办：控制器是异步的，
    // 而"摆待办"与"外壳建好"谁先谁后并不固定（测试里就是先攒待办再挂外壳；
    // 真机上启动比对回来得早、外壳还在建也是同一件事）。
    // 只听通知的话，这种情况下那扇面板就一直不出现。
    _open(_drainPending);
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    super.dispose();
  }

  void _onAppChanged() {
    if (!mounted || _sheetsOpen > 0) return;
    _open(_drainPending);
  }

  /// 看一眼控制器手上有哪些待办，按优先级端出**一扇**面板。
  ///
  /// 优先级是有讲究的：本次改动的差异面板先（它是"你刚做的事"），
  /// 然后是开机那扇二选一，最后才是"连不上"的警告。
  ///
  /// 返回 `Future` 只是为了让 [_open] 能等它 —— 实际等待发生在它调的那三个
  /// `_ask*` / `_warn*` 里（面板关掉才回来），门数因此正好关到面板收场。
  Future<void> _drainPending() async {
    if (!mounted) return;
    final diff = widget.app.pendingAutoPushDiff;
    if (diff != null) {
      await _askAutoPush(diff);
      return;
    }
    final startup = widget.app.pendingStartupSync;
    if (startup != null) {
      await _askStartupSync(startup);
      return;
    }
    final offline = widget.app.pendingStartupOfflineWarning;
    if (offline != null) {
      await _warnOffline(offline);
    }
  }

  /// 记上门数 → 排到帧后 → 弹完再减回去。
  ///
  /// 门数在这里就加，是因为 `addPostFrameCallback` 与 `await` 之间还会回到监听里：
  /// 同一帧连着两条通知（比如"摆面板"与"胶囊变了"）会各排一次回调，
  /// 于是同一扇面板弹两遍。
  ///
  /// 监听回调是在 `notifyListeners()` 里跑的，那一帧不能开路由 —— 所以一律挪到帧后。
  void _open(Future<void> Function() sheet) {
    _sheetsOpen += 1;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted) return;
        await sheet();
      } finally {
        _sheetsOpen -= 1;
      }
    });
  }

  /// 「回到主页自动同步」走到"云端那份会被覆盖"这一步时的问法。
  ///
  /// 只在**真有偏差**时才走到这里（没偏差的直接传了，见 `autoSyncAfterHome`）——
  /// 弹一次能看清楚的改动清单，比让用户事后去 GitHub 上猜自己推了什么强。
  Future<void> _askAutoPush(StoreDiff diff) async {
    final meta = widget.app.pendingAutoPushMeta;
    final choice = await showStoreDiffSheet(
      widget.shellContext,
      diff: diff,
      title: '本次改动需要推送',
      baseLabel: '云端数据，将被覆盖',
      targetLabel: '这台手机，将推送至云端',
      confirmLabel: '推送',
      cancelLabel: '暂不推送',
      // 两行对照：**云端第一行、本地第二行**（用户口径）。
      // ⚠️ 这扇面板的方向是"推"，`baseStore` 是云端 —— 不能交给面板按角色打标签，
      // 那会把云端排到第二行，与固定读法相反。
      cloudLine: (meta?.cloudStore == null || meta?.localStore == null)
          ? null
          : recordCountLine(
              sideLabel: '云端',
              store: meta!.cloudStore!,
              shortCommit: meta.cloudCommit,
            ),
      localLine: (meta?.cloudStore == null || meta?.localStore == null)
          ? null
          : recordCountLine(
              sideLabel: '本地',
              store: meta!.localStore!,
              shortCommit: meta.localCommit,
            ),
    );
    if (!mounted) return;
    // 只有点了「推送」才传。点了「暂不推送」，或者点空白/返回键划走，
    // 在这一屏是同一个意思：这一次不推（不记成失败）。
    if (choice == DiffSheetResult.confirm) {
      await widget.app.confirmPendingAutoPush();
    } else {
      widget.app.cancelPendingAutoPush();
    }
  }

  /// 每次进软件的静默比对发现"两边对不上"时的那一屏（需求⑤）。
  ///
  /// 两个按钮**都真的会改数据**（一个把本机推上去、一个拿云端盖掉本机），
  /// 所以这扇面板**点空白关不掉**（`barrierDismissible: false`）：
  /// 要退只有返回键 —— 那等于"我还没想好"，一个字节都不动，右上角留一枚黄胶囊。
  ///
  /// 例外是 [StartupSyncRequest.pullOnly]（本机 0 条）：那一支上"推上去"是
  /// 被禁止的动作，所以**主按钮根本不出现**，只剩「使用云端数据」
  /// （ADR-095 第 ② 条）。
  Future<void> _askStartupSync(StartupSyncRequest request) async {
    final choice = await showStoreDiffSheet(
      widget.shellContext,
      diff: request.diff,
      title: '云端和这台手机对不上',
      baseLabel: '云端数据',
      targetLabel: '这台手机',
      confirmLabel: '覆盖云端数据',
      cancelLabel: '使用云端数据',
      barrierDismissible: false,
      hideConfirm: request.pullOnly,
      note: request.message,
      // 两行对照：**云端第一行、本地第二行**（用户口径）。
      cloudLine: request.cloudStore == null || request.localStore == null
          ? null
          : recordCountLine(
              sideLabel: '云端',
              store: request.cloudStore!,
              shortCommit: request.cloudCommit,
            ),
      localLine: request.cloudStore == null || request.localStore == null
          ? null
          : recordCountLine(
              sideLabel: '本地',
              store: request.localStore!,
              shortCommit: request.localCommit,
            ),
    );
    if (!mounted) return;
    switch (choice) {
      case DiffSheetResult.confirm:
        await widget.app.acceptStartupPush();
      case DiffSheetResult.cancel:
        await widget.app.acceptStartupPull();
      case DiffSheetResult.dismissed:
        widget.app.dismissStartupSync();
    }
  }

  /// 连不上 GitHub 时的警告（需求⑤）：说清"照常编辑也行，但这段时间跟云端对不上"。
  ///
  /// 点掉之后调 `ackStartupOfflineWarning`：当天不再弹，但右上那枚
  /// 「GitHub 未连接」的黄胶囊**留着**（下一次同步成功才收）。
  Future<void> _warnOffline(String reason) async {
    await showDialog<void>(
      context: widget.shellContext,
      builder: (dialogContext) => AlertDialog(
        title: const Text('连不上 GitHub'),
        content: Text(
          '${reason.isEmpty ? '没能连上 api.github.com。' : reason}\n\n'
          '现在照常编辑不受影响，但这段时间的改动跟云端对不上：'
          '连上之后请回同步页上传一次；这期间不要在另一台设备上同时修改。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    widget.app.ackStartupOfflineWarning();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
