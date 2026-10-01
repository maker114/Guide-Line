import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/auto_sync_state.dart';
import '../../core/rules/archive_zone.dart';
import '../common/sync_status_indicator.dart';
import '../events/event_tab.dart';
import '../inspiration/inspiration_tab.dart';
import '../more/all_tasks_page.dart';
import '../more/archive_page.dart';
import '../more/more_tab.dart';
import '../more/search_page.dart';
import '../more/upcoming_page.dart';
import '../projects/project_tab.dart';
import '../shell_banners.dart';

/// 窗口宽度到了这个数，就换桌面外壳（侧栏 + 一条整体标题栏）。
///
/// 840 是 Flutter 官方 Material 断点表里 `compact` 的上界
/// （`compact` < 600 ≤ `medium` < 840 ≤ `expanded`）—— 名字取自成表的档位名，
/// 不自己发明数字，将来要挪也只挪这一个常量。
///
/// 为什么不留一个"再窄也还有侧栏"的中间态：宽度不够时侧栏会把正文挤成一条，
/// 与其做三档，不如两档 —— 窄了退回手机那套底部四格（本来就为窄屏做的），
/// 宽了才给侧栏。两个外壳是**互相兜底**的关系，不是新旧替代。
const double desktopMinWidth = 840;

/// 侧栏的八项。顺序就是栏里的顺序。
///
/// 与手机那四个 Tab 的关系：
///   · 灵感 / 项目 / 事件 三项**就是**手机的前三个 Tab；
///   · 手机第四个「更多」在桌面**拆成了五项**（今天到期 / 全部任务 / 搜索 / 归档区 /
///     设置）—— 手机上用一个列表装下这些入口，是因为底栏一格就那么大；
///     桌面上侧栏竖向空间够，每一项都值得自己一格，少点一次。
enum _NavItem {
  inspiration('灵感', Icons.edit_note_outlined, Icons.edit_note),
  projects('项目', Icons.account_tree_outlined, Icons.account_tree),
  events('事件', Icons.timeline_outlined, Icons.timeline),
  upcoming('今天 / 本周', Icons.event_available_outlined, Icons.event_available),
  allTasks('全部任务', Icons.checklist_outlined, Icons.checklist),
  search('搜索', Icons.search_outlined, Icons.search),
  archive('归档区', Icons.inventory_2_outlined, Icons.inventory_2),
  settings('设置', Icons.settings_outlined, Icons.settings);

  const _NavItem(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 电脑端外壳（ADR-094 第 ④ 条的"后续那一轮"）：**侧栏 + 一条整体标题栏 + 内容区**。
///
/// ## 为什么是照《归档电脑端》的样子**重搭**，而不是把它的 UI 搬过来
///
/// `archive/desktop-v1` 里那套 `board1_page` / `board2_page` / `projects_view` /
/// `inspiration_panel` 是**按旧契约写的**（四文档信封、旧 `AppController`、
/// `ws.run` / `exportTo` / `previewImport` 那些签名）。搬过来要接的调用面约 15 处，
/// 而现版这四页已经多长出 AI 整理成正文、交接说明、GitHub 备份、归档三档合流等
/// 二十来项能力 —— 照搬等于把这些能力删掉重写一遍。
///
/// 所以这里取的是它的**形**：侧栏一项一格、顶部一条整体标题栏、正文占满剩下
/// 全部宽度与高度；页面本身**一律用现在的**（`ProjectTab` / `EventTab` / …），
/// 业务规则一行不动，`AppController` 一行不改。
///
/// ## 侧栏为什么是 `NavigationRail` 而不是自绘
///
/// 手机底栏自绘，是因为 `NavigationBar` 的选中指示器框尺寸写死（见
/// `app_shell.dart` 顶部那大段注释）。`NavigationRail` 没这个问题：它的选中指示
/// 跟着行高走、图标与文字都是 Material 自己的规矩，而且右键菜单、高对比度、
/// 键盘上下键这一套它是免费给的 —— 桌面上"用键盘干活"是常态，
/// 为一个能自己控制的形状把它全部丢掉不划算。
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, required this.app});

  final AppController app;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  _NavItem _selected = _NavItem.projects;

  /// 回收站到期清理的提示关掉没有（与手机外壳同一口径：关掉就是本次运行不再出现）。
  bool _trashNoticeClosed = false;

  // 这里**不再自己跑开机比对**（ADR-095 第 ⑥ 条）。
  //
  // 以前这个 `initState` 会调一次 `startupSyncCheck()`，理由是"谁在台前谁负责
  // 这一趟"—— 但换壳并不重启进程，于是宽窗口下手机外壳那一趟与这一趟会**同时**
  // 发出去（连两次网、可能弹两次面板）；更要紧的是**它比出来的结果没人端出来**：
  // 电脑端原先没有监听 `pendingAutoPushDiff` / `pendingStartupSync` /
  // `pendingStartupOfflineWarning` 的地方，于是"开机比对发现两边对不上"只留下
  // 一枚黄胶囊，面板永远不出现，用户想选都没地方选。
  //
  // 现在的分工：**跑那一趟与端那三扇窗都在 `AppShell._buildMobile` 外面那一层**
  // （`AutoSyncPanels`），它在窗口宽窄变化时不重建，跑一次就是一次。
  // 这个外壳只负责把内容画出来 + 标题栏上那枚指示器。

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              NavigationRail(
                extended: true,
                // 210 这个宽度是照归档电脑端那套抄的（`desktop_shell.dart` 里
                // 同一行 `minExtendedWidth: 210`）：够写下"今天 / 本周"这种
                // 两段式标签而不换行。
                minExtendedWidth: 210,
                selectedIndex: _NavItem.values.indexOf(_selected),
                onDestinationSelected: (index) {
                  setState(() => _selected = _NavItem.values[index]);
                },
                destinations: <NavigationRailDestination>[
                  for (final item in _NavItem.values)
                    NavigationRailDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selectedIcon),
                      label: Text(item.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _header(context, app),
                    if (app.startupWarnings.isNotEmpty)
                      ShellWarningBanner(
                        messages: app.startupWarnings,
                        onTap: () => showDataIncident(context, app),
                      ),
                    if (app.lastTrashPurgedCount > 0 && !_trashNoticeClosed)
                      ShellWarningBanner(
                        messages: <String>[
                          '回收站有 ${app.lastTrashPurgedCount} 条已超过 $trashRetentionDays 天，已自动清除',
                        ],
                        onDismiss: () => setState(() => _trashNoticeClosed = true),
                      ),
                    if (app.overdueCount > 0)
                      ShellDueBanner(count: app.overdueCount, app: app),
                    // 内容区：八页都建出来、靠 `IndexedStack` 切换。
                    //
                    // 为什么不用 `PageView`（手机那套）：桌面上没有"左右滑一页"
                    // 这个手势，而 `PageView` 会按当前宽度把**相邻页**也建出来，
                    // 白建一半。`IndexedStack` 只显示一个、其余留在树上，
                    // 于是每页的滚动位置、展开状态、输入到一半的残句都还在 ——
                    // 手机那边靠 `_KeepAlivePage` 拿到的正是这个效果。
                    Expanded(
                      child: IndexedStack(
                        index: _NavItem.values.indexOf(_selected),
                        children: <Widget>[
                          InspirationTab(app: app),
                          ProjectTab(app: app),
                          EventTab(app: app),
                          UpcomingTasksPage(app: app, embedded: true),
                          AllTasksPage(app: app, embedded: true),
                          SearchPage(app: app, embedded: true),
                          ArchivePage(app: app, embedded: true),
                          MoreTab(app: app),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 顶部那条整体标题栏：当前栏目标题 + 同步指示器 + 关于。
  ///
  /// 与手机外壳的标题栏同一个职责，但不跟着翻页动画走（桌面上页面不滑动，
  /// 没有"连续页位置"这个数可跟）。栏目标题**不重复画在正文里** ——
  /// 嵌进来的那几页因此都关掉了自己的 `AppBar`（`embedded: true`）。
  Widget _header(BuildContext context, AppController app) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Row(
        children: <Widget>[
          Text(_selected.label, style: theme.textTheme.headlineSmall),
          const Spacer(),
          SyncStatusIndicator(
            state: app.autoSync,
            onShowReason: _showAutoSyncReason,
          ),
          TextButton(
            onPressed: () => showAboutApp(context, app),
            child: const Text('关于'),
          ),
        ],
      ),
    );
  }

  /// 同步没完成的原因（点右上角那枚黄/红胶囊看）—— 原话照摆，不去掉细节。
  ///
  /// 与手机外壳同一套文案（标题按状态走：红的 `failed` 是"这次真的没传上去"，
  /// 其余直接拿状态自己的 `label` 当标题）。两处都写是因为它读的是**当前这个
  /// 外壳的 `context`**，提到公共文件反而要再传一层 context。
  Future<void> _showAutoSyncReason() async {
    final state = widget.app.autoSync;
    final reason = state.reason;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          state.phase == AutoSyncPhase.failed ? '这次没能上传' : state.label,
        ),
        content: Text(reason.isEmpty ? '没有拿到原因。' : reason),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
