import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/rules/cascade.dart';
import '../../core/rules/handoff_export.dart';
import '../../features/workspace.dart';
import '../common/animated_collapse.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/due_sheet.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/status_selector.dart';
import '../inspiration/inspiration_selection.dart';
import '../inspiration/merge_editor_page.dart';
import '../theme/shape_tokens.dart';
import 'ai_preview_page.dart';
import 'handoff_preview_page.dart';
import 'project_actions.dart';
import 'project_checklist.dart';

/// 项目详情：**目标**看全套字段，**分类**只看下级与汇总。
///
/// 角色判据（《定义与边界》§2.1）：**有下级（未归档、未删除的直属下级项目）
/// 就是分类，没有下级就是目标**，与深度无关。
///
///   · **目标**：有什么问题 / 思路 + 实现清单 + 如何解决 + 下级 + 待处理灵感；
///   · **分类**：名字、标识色、下级列表、汇总、以及「移到其它分类」等动作 ——
///     **不显示目的 / 如何解决 / 实现清单 / 日期**，也只从**目标**发起灵感合并。
///
/// 名称不在这里改（标题栏已经写着项目名了，正文再放一遍是重复）：改名入口
/// 收在标题右侧的三个点里，点「重命名」之后标题栏原地变成输入框。
class ProjectDetailPage extends StatefulWidget {
  const ProjectDetailPage({super.key, required this.app, required this.projectId});

  final AppController app;
  final String projectId;

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage> {
  /// 标题栏是否处于"改名字"状态
  bool _renaming = false;
  final TextEditingController _titleController = TextEditingController();

  AppController get app => widget.app;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  void _startRename(Project project) {
    _titleController
      ..text = project.title
      // 全选：进来就能直接覆盖着写，长名字不用先删一遍
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: project.title.length,
      );
    setState(() => _renaming = true);
  }

  void _cancelRename() => setState(() => _renaming = false);

  /// 提交改名。**空名字不提交、保持原名** —— 与 `InlineTextField` 同一条约定
  /// （必填项被清空时不能把标题清没）。
  void _commitRename(Project project) {
    final next = _titleController.text.trim();
    setState(() => _renaming = false);
    if (next.isEmpty || next == project.title) return;
    final error = app.run(() => app.ws.updateProject(project.id, title: next));
    if (error != null && mounted) showToast(context, error, error: true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final ws = app.ws;
        final project = ws.findProject(widget.projectId);
        if (project == null || project.deleted) {
          return Scaffold(
            appBar: AppBar(title: const Text('项目')),
            body: const Center(child: Text('这个项目已被删除')),
          );
        }

        final parent = project.parentId == null ? null : ws.findProject(project.parentId!);
        final children = ws.childProjectsOf(widget.projectId);
        // 有下级 = 分类（Q2）；分类不装灵感，所以这一页不为它取灵感
        final isCategory = children.isNotEmpty;
        final inspirations = isCategory
            ? const <Inspiration>[]
            : (ws.liveInspirations
                  .where((i) => i.isPending && i.projectId == widget.projectId)
                  .toList(growable: false)
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));

        return Scaffold(
          appBar: AppBar(
            title: _renaming
                ? TextField(
                    controller: _titleController,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    style: Theme.of(context).textTheme.titleLarge,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '项目名',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _commitRename(project),
                  )
                : _DetailTitle(project: project),
            actions: _renaming
                ? <Widget>[
                    IconButton(
                      tooltip: '取消',
                      icon: const Icon(Icons.close),
                      onPressed: _cancelRename,
                    ),
                    IconButton(
                      tooltip: '保存',
                      icon: const Icon(Icons.check),
                      onPressed: () => _commitRename(project),
                    ),
                  ]
                : <Widget>[
                    // 标识色与日期**收进标题栏**（2026-09-27 实机反馈：
                    // 把项目界面里的调色盘和日期设置挪到顶部的标题栏中）。
                    // 它们本来就是"设置一次就不再动"的两项，摆在正文首屏只是
                    // 白占一行高度；标题栏右侧正好是它们的位置 ——
                    // 与事件详情页的调色盘图标也在标题栏，观感一致。
                    _IconActions(
                      app: app,
                      project: project,
                      // 分类**不给设日期**（《定义与边界》§2.1），但设过的那个
                      // 必须露出来，否则它再也点不到、清不掉。
                      showDate: !isCategory || project.date != null,
                    ),
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      onSelected: (value) async {
                        switch (value) {
                          case 'rename':
                            _startRename(project);
                            break;
                          case 'handoff':
                            if (!context.mounted) return;
                            await _exportHandoff(context, project);
                            break;
                          case 'move':
                            await moveProjectAction(
                              context,
                              app,
                              project.id,
                              title: isCategory ? '移到其它分类' : '移动到…',
                            );
                            break;
                          case 'resetImplementation':
                            if (!context.mounted) return;
                            await _reset(context, project);
                            break;
                          case 'clearDone':
                            if (!context.mounted) return;
                            await _clearDoneItems(context, project);
                            break;
                          case 'archive':
                            await archiveProjectAction(context, app, project.id, archived: true);
                            break;
                          case 'delete':
                            if (!context.mounted) return;
                            await deleteProjectAction(context, app, project.id);
                            if (context.mounted) Navigator.of(context).maybePop();
                            break;
                        }
                      },
                      itemBuilder: (_) => <PopupMenuEntry<String>>[
                        const PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
                        // 分类与目标**都给这个入口**（2026-09-27 实机反馈：
                        // 分类界面应当可以统一导出其子项目的所有条目）——
                        // 只是同一件东西的两种范围：目标导自己，分类导整棵子树。
                        PopupMenuItem<String>(
                          value: 'handoff',
                          child: Text(isCategory ? '导出分类说明…' : '导出交接说明…'),
                        ),
                        PopupMenuItem<String>(
                          value: 'move',
                          child: Text(isCategory ? '移到其它分类' : '移动到…'),
                        ),
                        // 清理与重置**不再单独分组**（2026-09-28 实机反馈：把
                        // 「移动…」与「清除已完成条目」之间那条分割线去掉）——
                        // 菜单项本身已经把动作说清了，多一条横线只是切碎视线。
                        PopupMenuItem<String>(
                          value: 'clearDone',
                          // 只在有已勾选条目时给：一个永远点不动的项只会让人猜
                          enabled: clearDoneScopeOf(project, app).items > 0,
                          child: const Text('清除已完成条目…'),
                        ),
                        // 分类与项目的重置**范围不同**：
                        //   · 分类：只清下面那些目标的实现 —— 分类自己的「总纲领」
                        //     是它的定义，清掉等于把这个分类注销；
                        //   · 项目：清它自己的实现。
                        // 「重置整个项目」已按实机反馈**去掉**（2026-09-28）：
                        // 清空「有什么问题 / 思路」用编辑框自己删更直接，
                        // 而菜单里摆一个"会把这一条彻底清干净"的项太容易误点。
                        PopupMenuItem<String>(
                          value: 'resetImplementation',
                          child: Text(
                            isCategory ? '重置下级所有实现…' : '重置所有实现…',
                          ),
                        ),
                        const PopupMenuItem<String>(value: 'archive', child: Text('归档')),
                        const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              if (parent != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.subdirectory_arrow_right, size: 18),
                  title: Text('属于「${parent.title}」', style: Theme.of(context).textTheme.labelMedium),
                ),
              // 分类与目标看到的是**两套正文**（Q2）：
              //   分类写**总纲领**（ADR-069：这一类要一起往哪走）+ 下级列表；
              //   目标才有一整套字段（有什么问题 / 思路、清单、如何解决、灵感）。
              //
              // 「汇总」卡已删（2026-09-27 实机反馈）：分类里装的是同一个方向的几件事，
              // 这个方向理应有一个总纲领 —— 那句"含 N 个目标 / 清单 x/y"既不是纲领也不是
              // 内容，占着首屏位置却回答不了任何问题。数字在下级行上就能看到。
              if (isCategory) ...<Widget>[
                // 标识色与日期已经收进标题栏（见上面 AppBar 的 `_IconActions`），
                // 这里只留分类自己的正文。
                _TextField(
                  title: '总纲领',
                  hint: '这一类要一起往哪走',
                  value: project.purpose,
                  onSubmitted: (value) =>
                      app.run(() => ws.updateProject(project.id, purpose: value)),
                ),
                _ChildrenField(app: app, project: project, children: children),
              ] else ...<Widget>[
                _TextField(
                  title: '有什么问题 / 思路',
                  hint: '想解决什么问题、有什么思路',
                  value: project.purpose,
                  onSubmitted: (value) =>
                      app.run(() => ws.updateProject(project.id, purpose: value)),
                ),
                // 「实现」有两种表达方式（ADR-077）：结构化的**清单**，或整段的
                // **文本**（「如何解决」）。2026-09-27 实机反馈之前，两张卡一直
                // 同时摆着 —— 有清单时正文默认收起，等于一屏里一半是折叠着的字。
                // 现在改成**二选一**：切过去就看得见另一种，两个字段一个都不动。
                _ImplementationField(
                  app: app,
                  project: project,
                  onSplitFromImplementation: () => _splitIntoItems(context, project),
                  onChecklistActions: () => _showChecklistActions(context, project),
                ),
                _ChildrenField(app: app, project: project, children: children),
                _InspirationsField(
                  app: app,
                  project: project,
                  inspirations: inspirations,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 「清除已完成条目…」（2026-09-28 实机反馈：在分类界面里可以批量清除已完成清单）。
  ///
  /// 范围与「重置」同一套（本级 + 所有**直属**下级），但**只删已勾选的**：
  /// 没做完的条目是还没交付的计划，批量动作误伤它们的代价远大于收益。
  /// 清完清单里只剩未完成项，可以接着排下一批 —— 这也是它与「重置」的分工：
  /// 重置是"这些都作废了"，这里是"做完的归档掉"。
  Future<void> _clearDoneItems(BuildContext context, Project project) async {
    final scope = clearDoneScopeOf(project, app);
    if (scope.items == 0) return;

    final ok = await confirmAction(
      context,
      title: '清除已完成条目',
      message: '会删掉 ${scope.projects} 个项目里「已勾选」的 ${scope.items} 条清单条目。\n'
          '没勾的条目、正文、名字都不动；删掉的找不回来（清单没有回收站）。',
      confirmLabel: '清除',
      danger: true,
    );
    if (!ok || !context.mounted) return;

    final error = app.run(() => app.clearDoneItems(project.id));
    if (!context.mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已清除 ${scope.items} 条已完成条目');
  }

  /// 一次「重置」（2026-09-28 实机反馈：放进 ⋮ 里，注意二次确认、明确警告）。
  ///
  /// 现在**只有一种范围**：清「实现」（正文 + 清单条目）。分类与项目的差别只在
  /// "动谁"：
  ///   · **项目**：清它自己的实现；
  ///   · **分类**：清它下面所有目标的实现 —— 分类自己的「总纲领」是它的定义，
  ///     清掉等于把这个分类注销，所以不动（同一批反馈的另一条）。
  ///
  /// 「重置整个项目」（连「有什么问题 / 思路」一起清）已按实机反馈**去掉**：
  /// 清空那个字段用编辑框自己删更直接，而菜单里摆一个"会把这一条彻底清干净"的
  /// 项太容易误点。
  ///
  /// 范围（本级 + 所有**直属**下级）与影响条数都在确认框里说清 —— 这句话涉及
  /// "会丢多少东西"，必须让用户在按下之前看得见。执行前还会留一份可退回的档
  /// （一份只值一次反悔），确认之后给一句带「退回上一版」的提示。
  Future<void> _reset(BuildContext context, Project project) async {
    final impact = app.resetImpactOf(project.id);
    final scope = app.resetScopeOf(project.id);
    // 分类页那一条只动下级，不动分类自己
    final isCategory = app.ws.childProjectsOf(project.id).isNotEmpty;
    final affected = isCategory ? impact.projects - 1 : impact.projects;

    final title = isCategory ? '重置下级所有实现' : '重置所有实现';
    const what = '正文与清单条目会被清空';
    final range = isCategory
        ? '会动它下面 $affected 个目标的实现；分类自己的「总纲领」不动'
        : (affected <= 1
            ? '只会动「${project.title}」这一个项目'
            : '会连同它的 ${affected - 1} 个下级目标一起动，共 $affected 个项目');

    final ok = await confirmAction(
      context,
      title: title,
      message: '$range，$what'
          '（清单 ${impact.items} 条）—— 名字、标识色、日期与归档状态都不动。\n'
          '不能撤销：重置没有回收站，退回只给一次（执行后提示里那个「退回上一版」）。',
      confirmLabel: '重置',
      danger: true,
    );
    if (!ok || !context.mounted) return;

    // 分类页只清下级：把自己从范围里摘掉
    final ids = <String>[
      for (final each in scope)
        if (!(isCategory && each.id == project.id)) each.id,
    ];
    final error = app.resetProject(
      project.id,
      implementationsOnly: true,
      overrideIds: isCategory ? ids : null,
    );
    if (!context.mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    _announceReset(context, title, affected);
  }

  /// 重置之后的提示：**带上一次反悔的入口**。
  ///
  /// 三条实机反馈都在这一个 `SnackBar` 上（2026-09-28）：
  ///   · **"弹窗是黑色的"** —— `SnackBar` 的默认底色取 `inverseSurface`
  ///     （深色主题下就是一块黑），与这一页的其它提示不是一个观感。
  ///     这里改成与 `showToast` 同一套：`inverseSurface` 只用于普通提示，
  ///     而这条要**长期留着让用户能点**，所以给它明确的 `surfaceContainerHighest`
  ///     底 + `onSurface` 字，深浅两套主题下都是"应用自己的面板"。
  ///   · **"返回上一版的提示不太清楚"** —— 文案改成动词开头、把后果写全。
  ///   · **"似乎不会自行消失"** —— 带 `action` 的 `SnackBar` 默认**要用户处理**
  ///     （`SnackBarAction` 会让它一直挂着）；而且原来点完按钮还会 `showToast`，
  ///     那是**又排一条**在后面，第一条不消失、第二条永远出不来。
  ///     现在显式给 8 秒（够看清、够点），并且不再往里塞第二条提示。
  void _announceReset(BuildContext context, String title, int projectCount) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final scheme = Theme.of(context).colorScheme;
    // 先把还在排队 / 正在显示的那条收掉：否则这一条要排队，看起来"点了没反应"
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          backgroundColor: scheme.surfaceContainerHighest,
          content: Text(
            '$title完成：$projectCount 个项目已清空。点右边可以退回来（只值一次）',
            style: TextStyle(color: scheme.onSurface),
          ),
          action: SnackBarAction(
            label: '退回上一版',
            textColor: scheme.primary,
            onPressed: () {
              final error = app.revertProjectReset();
              if (error == null) return;
              // 只在这一种情况下再给一句：退回**没成功**是用户必须知道的
              // （成功时列表自己就变回去了，不需要多说一句 —— 多说一句就会
              //  把这条带按钮的提示挤掉，那是上一版"提示不消失"的另一半原因）
              showToast(context, error, error: true);
            },
          ),
        ),
      );
  }

  /// 生成并把用户送到**交接说明预览页**（真正写文件在那一步）。
  ///
  /// 一个入口、两种范围：
  ///   · **目标** —— 只导它自己（老行为，一个字没改）；
  ///   · **分类** —— 导它自己 + 所有下级目标（实机反馈：分类界面要能
  ///     "统一导出其子项目的所有条目"）。
  ///
  /// 分类那一侧的取数只说三件事：**要哪些目标**、**每个目标带哪些灵感**、
  /// **不含哪些**。「不含」定死两条：已归档的与已删除的下级一律不进 ——
  /// 分类里装的是**还活着**的目标（《定义与边界》§2.1），把归档掉的东西
  /// 塞进一份给外人读的说明里，只会让对面以为它还在做。
  Future<void> _exportHandoff(BuildContext context, Project project) async {
    final children = app.ws.childProjectsOf(project.id);
    final isCategory = children.isNotEmpty;
    final ws = app.ws;

    // 待处理灵感：目标导自己的，分类导整棵子树里各个目标的
    List<Inspiration> pendingOf(String projectId) => ws.liveInspirations
        .where((i) => i.isPending && i.projectId == projectId)
        .toList(growable: false);

    final String markdown;
    if (!isCategory) {
      markdown = HandoffExport.build(
        project: project,
        inspirations: pendingOf(project.id),
        now: DateTime.now(),
      );
    } else {
      final inspirationsByProject = <String, List<Inspiration>>{
        for (final child in children) child.id: pendingOf(child.id),
      };
      markdown = HandoffExport.buildCategory(
        category: project,
        children: children,
        inspirationsByProject: inspirationsByProject,
        now: DateTime.now(),
      );
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HandoffPreviewPage(
          app: app,
          projectId: project.id,
          // 分类顺带说到"含几个目标"：一份说明里装了几件事，用户得先知道
          projectTitle: isCategory
              ? '${project.title}（含 ${children.length} 个目标）'
              : project.title,
          markdown: markdown,
        ),
      ),
    );
  }

  /// 清单区的**整理入口**（Q32）：把"按正文重拆 / 清空清单"这两件平时不用、
  /// 但拆错了必须找得到的事收在一处，入口挂在清单卡片的标题行上。
  ///
  /// 两件事都**只动清单、一个字都不动正文**（《定义与边界》§2.1：清单不参与
  /// 完成判定，也与事件里的任务零联动）。
  Future<void> _showChecklistActions(BuildContext context, Project project) async {
    final items = project.items;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('整理清单', style: theme.textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.splitscreen_outlined),
                title: const Text('按正文重拆'),
                // 说清代价：怎么拆是猜的，而且会顶掉现有条目 —— 不可逆
                subtitle: const Text('按行拆开正文；怎么拆是猜的'),
                enabled: project.implementation.trim().isNotEmpty,
                onTap: () => Navigator.of(sheetContext).pop('split'),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_remove),
                title: const Text('清空清单'),
                subtitle: Text(
                  items.isEmpty ? '现在就没有条目' : '会删掉这 ${items.length} 条；正文不受影响',
                ),
                enabled: items.isNotEmpty,
                onTap: () => Navigator.of(sheetContext).pop('clear'),
              ),
            ],
          ),
        );
      },
    );
    if (action == null || !context.mounted) return;
    if (action == 'clear') {
      await _clearItems(context, project);
      return;
    }
    await _splitIntoItems(context, project);
  }

  /// 清空清单（**只清条目，正文一个字都不动**）。
  ///
  /// 二次确认是必须的：条目本身没有回收站，删掉就只能靠正文重新拆一次
  /// —— 而"怎么拆"本来就是猜的，等于找不回来。
  Future<void> _clearItems(BuildContext context, Project project) async {
    final count = project.items.length;
    if (count == 0) return;

    final ok = await confirmAction(
      context,
      title: '清空清单',
      message: '会删掉现在这 $count 条条目。\n'
          '正文（「如何解决」）不受影响，还在原地。',
      confirmLabel: '清空',
      danger: true,
    );
    if (!ok || !context.mounted) return;

    final error = app.run(() => app.ws.clearProjectItems(project.id));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) showToast(context, '已清空 $count 条，正文未改动');
  }

  /// 把「实现」正文按行拆成清单条目（**显式动作**）。
  ///
  /// 不在读取时自动拆：把一段中文按行拆开是不可逆的猜测，自动拆等于
  /// 第一次打开就悄悄改了数据形态。拆之前说清会发生什么，拆完报告条数。
  Future<void> _splitIntoItems(BuildContext context, Project project) async {
    final lines = Workspace.splitImplementationLines(project.implementation);
    if (lines.isEmpty) {
      showToast(context, '正文里没有可拆成条目的内容', error: true);
      return;
    }

    if (project.items.isNotEmpty) {
      final ok = await confirmAction(
        context,
        title: '从正文重拆',
        message: '会先清空现在这 ${project.items.length} 条，再按正文重新拆成 ${lines.length} 条'
            ' —— 怎么拆是猜的，拆错了只能一条条改回来。\n'
            '正文本身不会动。',
        confirmLabel: '重拆',
        danger: true,
      );
      if (!ok || !context.mounted) return;
      final cleared = app.run(() => app.ws.clearProjectItems(project.id));
      if (cleared != null) {
        if (context.mounted) showToast(context, cleared, error: true);
        return;
      }
    }

    final error = app.run(() => app.ws.splitImplementationIntoItems(project.id));
    if (error != null) {
      if (context.mounted) showToast(context, error, error: true);
      return;
    }
    if (context.mounted) {
      showToast(context, '已拆成 ${lines.length} 条');
    }
  }
}

/// 标题栏上的**标识色竖条 + 项目名**。
///
/// 竖条与项目树行首是同一个控件（`ProjectColorBar`）：进了详情页也知道
/// 自己看的是哪个颜色的项目（实机反馈）。没设色时是同一根灰条，
/// 位置永远占住，标题不会因为"有的有颜色、有的没有"而左右跳。
class _DetailTitle extends StatelessWidget {
  const _DetailTitle({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        ProjectColorBar(color: project.color, height: 22),
        const SizedBox(width: 8),
        Expanded(
          child: Text(project.title, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

/// 「实现」的两种模式：**清单**（结构化、可勾选）与**文本**（整段说明）。
enum ImplementationMode {
  checklist('清单'),
  text('文本');

  const ImplementationMode(this.label);

  final String label;
}

/// 「实现」这一块：标题行一个**二选一**切换，下面画对应的那一种。
///
/// 为什么合成一块（ADR-077）：清单与正文是同一件事的两种写法 ——
/// "这个项目打算怎么做"。从前两张卡同时摆着，有清单时正文默认收起，
/// 那一屏就永远有一半是折叠着的字，用户得先想"我要看的是哪一半"。
/// 现在是二选一：**切过去的动作本身就是"我要看那一种"**。
///
/// 底线（不许因为合并而破坏）：底层 `items` 与 `implementation`
/// 是**两个独立字段**，切模式**只换显示**，一个字都不清空、也不互相覆盖。
class _ImplementationField extends StatefulWidget {
  const _ImplementationField({
    required this.app,
    required this.project,
    required this.onSplitFromImplementation,
    required this.onChecklistActions,
  });

  final AppController app;
  final Project project;
  final VoidCallback onSplitFromImplementation;
  final VoidCallback onChecklistActions;

  @override
  State<_ImplementationField> createState() => _ImplementationFieldState();
}

class _ImplementationFieldState extends State<_ImplementationField> {
  /// 当前看的是哪一种。`null` = 还没手动切过，用"有什么"来定。
  ///
  /// 为什么不进偏好：这是**看这一页时的临时视角**，不是一条长期设置。
  /// 但同一个项目在这一次会话里切过之后要留得住 —— 所以挂在 State 上，
  /// 靠 `ProjectDetailPage` 的 `ListenableBuilder` 重建时保持。
  ImplementationMode? _mode;

  /// 默认看哪一侧：**一律先给清单**。
  ///
  /// 三条理由，合起来就是"清单才是这一块的主视图"：
  ///   · 它是**能打勾的那一份**，日常打开项目要看的就是进度；
  ///   · 条目为空时它给出的"还没有条目 + 添加条目 + 从正文拆成条目"正是
  ///     一个刚建的项目需要的东西，而正文那一侧这时是一张白纸；
  ///   · 与合进这块之前的行为一致 —— 从前清单永远在、正文才是有条件收起的那一半，
  ///     所以"打开就能看见清单"这件事没有变过，变的只是另一半改成切过去看。
  ///
  /// 用户手动切过之后以手动为准（`_mode`）。
  ImplementationMode get _effective => _mode ?? ImplementationMode.checklist;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final mode = _effective;

    // 版式（2026-09-28 实机反馈"实现部分的 UI 和排布不美观"）：
    //
    //   ┌──────────────────────────────────────────┐
    //   │ 实现                        ╭──────╮      │  ← 标题行只有两样：标题 + 切换器
    //   │                             │清单│文本│     │
    //   │                             ╰──────╯      │
    //   │   ○ 一条条目                                │
    //   │   ＋ 添加条目                               │
    //   │   ✨ AI 整理成「如何解决」                     │
    //   └──────────────────────────────────────────┘
    //
    // 三条刻意的取舍：
    //   · **不再显示 `n/m` 进度**（实机反馈：不需要）—— 卡片里少一行数字；
    //   · **不在切换器下面画分割线**（实机反馈：不要）：切换器与内容之间
    //     用留白分开就够，画线反而多一道横杠；
    //   · **切换器与「未完成 / 已完成 / 已搁置」共用同一个胶囊控件**
    //     （`StatusPillSelector`，`stretch: false` 让它按内容宽排）——
    //     从前这里用的是 M3 `SegmentedButton`，带外框、和全页都不像。
    return _FieldCard(
      title: '实现',
      trailing: StatusPillSelector<ImplementationMode>(
        values: ImplementationMode.values,
        selected: mode,
        labelOf: (each) => each.label,
        stretch: false,
        onSelected: (value) => setState(() => _mode = value),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (mode == ImplementationMode.checklist)
            ProjectChecklist(app: widget.app, project: project)
          else
            _ImplementationBody(
              value: project.implementation,
              hasItems: project.items.isNotEmpty,
              onSubmit: (value) {
                // AI 整理后正文会被替换，空内容会被业务层拒绝（不让正文被清没）
                if (value.trim().isEmpty) return;
                final error = widget.app.run(
                  () => widget.app.ws.replaceImplementation(project.id, value),
                );
                if (error != null && context.mounted) {
                  showToast(context, error, error: true);
                }
              },
            ),
          // 两种模式各有一个**收尾动作**，都画在卡片底部（PL-B-1：动作降到内容下面）。
          // 谁是"这个方向上的下一步"，谁就出现在这里 —— 不需要两枚并列按钮。
          //
          // 名字跟着方向走（2026-09-28）：AI 那一步往哪边做，由"手上有什么"决定，
          // 所以这一行写的是它**这一次**会做的事。
          if (mode == ImplementationMode.checklist)
            _CardFootAction(
              icon: Icons.auto_awesome_outlined,
              label: 'AI 整理成「如何解决」',
              // 只在有清单**且 AI 总开关开着**时给入口 —— 关掉 AI 之后，
              // 项目里不该再出现任何"AI 整理"的字样（实机反馈）
              onTap: (project.items.isNotEmpty && widget.app.aiEnabled)
                  ? () => startAiSummarize(context, widget.app, project.id, project.title)
                  : null,
            )
          else ...<Widget>[
            // 正文侧：有正文就能**拆成条目**（从前这一步是本地的"按行硬拆"）
            if (project.implementation.trim().isNotEmpty && widget.app.aiEnabled)
              _CardFootAction(
                icon: Icons.auto_awesome_outlined,
                label: 'AI 拆成清单条目',
                onTap: () =>
                    startAiSummarize(context, widget.app, project.id, project.title),
              ),
            if (project.implementation.trim().isNotEmpty)
              _CardFootAction(
                icon: Icons.copy_all_outlined,
                label: '全部复制',
                trailing: '${project.implementation.trim().length} 字',
                onTap: () => _copyBody(context),
              ),
          ],
        ],
      ),
    );
  }

  /// 把「如何解决」全文拷进剪贴板。
  ///
  /// 拷的是**当前的正文原值**（不是编辑框里的半成品）：这一页的正文改完就落盘，
  /// 所以两者本来就一样；用原值可以避免"正在编辑、还没提交"时拷到半截。
  Future<void> _copyBody(BuildContext context) async {
    final text = widget.project.implementation.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showToast(context, '已复制');
  }
}

/// 「实现」卡片底部的**收尾动作**（两种模式各一个）。
///
/// 长成一条**整行的文字按钮**：它有图标、有文案、点整行都能触发，
/// 但**没有底色**——按《界面规范》§1，它是这一块里的次要动作，
/// 不该跟内容抢注意力（从前那枚「重拆 / 清空」胶囊就是反面例子）。
class _CardFootAction extends StatelessWidget {
  const _CardFootAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;

  /// `null` = 现在不能用（例如清单还是空的、或 AI 总开关关着）。
  /// 那时**整行不画** —— 一个灰掉的按钮只会让人点它。
  final VoidCallback? onTap;

  /// 右侧的补充说明（现在只有「全部复制」用它报字数）。
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppShapes.chipRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              if (trailing != null)
                Text(trailing!, style: theme.textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「如何解决」的**内容部分**（标题与卡片外壳由 `_FieldCard` 负责）。
///
/// 这一块是三样东西的共同落点 —— AI 整理写进来、交接导出从这里取、
/// 手写也写在这里（灵感合并不再写它，见 `Workspace.mergeInspiration`）。
///
/// **不再自己管展开 / 收起**（ADR-077）：那是"清单与正文同时存在"时代的东西，
/// 现在由外面那个模式切换决定要不要显示它，所以这里就是一个**始终展开的编辑区**。
///
/// **给它加了"自己的框"**（2026-09-28）：从前正文只有一行浅色提示、直接铺在
/// 卡片底上，而清单侧每一条都有勾选框当骨架 —— 同一张卡里两种密度。
/// 现在正文有一层 `filled` 底色 + 内边距，与清单侧对称。
class _ImplementationBody extends StatelessWidget {
  const _ImplementationBody({
    required this.value,
    required this.hasItems,
    required this.onSubmit,
  });

  /// 当前正文。
  final String value;

  /// 这个项目有没有清单条目 —— 决定空态提示该说什么。
  ///
  /// "有清单但正文是空的"是很常见的一步（先拆了清单、还没写正文），
  /// 那时得说清"这里空着不影响清单"，否则用户会以为数据丢了。
  final bool hasItems;

  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = value.trim().isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (empty && hasItems)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '正文还空着 —— 清单里的条目不受影响，切回「清单」就能看到',
              style: theme.textTheme.bodySmall,
            ),
          ),
        InlineTextField(
          value: value,
          hint: '打算怎么做',
          minLines: 1,
          maxLines: 12,
          allowEmpty: true,
          textStyle: theme.textTheme.bodyMedium,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decorated: true,
          onSubmitted: onSubmit,
        ),
      ],
    );
  }
}

/// 「标识色 / 日期」的图标入口 —— **挂在标题栏右侧**（`AppBar.actions`）。
///
/// 按实机反馈收成图标：这两项是**设置一次就不再动**的东西，各占一整行 ListTile
/// 太浪费纵向空间。再按 2026-09-27 的实机反馈，从正文首屏**挪进标题栏**：
/// 它们与"看这一页要干什么"无关，而标题栏右侧本来就是"关于这个项目本身"的位置。
///
/// 清除的路子：调色盘仍是长按（面板里也有「不用标识色」），
/// **日期则是点开日历面板、在面板里点「清除日期」** —— 长按这个手势
/// 曾经是唯一的清除路径，而提示也写在同一个长按的 tooltip 里，等于没有提示。
class _IconActions extends StatelessWidget {
  const _IconActions({
    required this.app,
    required this.project,
    this.showDate = true,
  });

  final AppController app;
  final Project project;

  /// 分类**没有日期**（《定义与边界》§2.1）—— 那时不给日期图标。
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorOfHex(project.color);
    final hasDate = project.date != null;
    // 项目没有完成态（Q1）：逾期只看日期，不再看 `status`
    final overdue = hasDate && isOverdue(project.date);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ClearableIcon(
          tooltip: color == null
              ? '标识色：点一下选'
              : '标识色 ${project.color}，长按可清除',
          icon: Icons.palette_outlined,
          color: color ?? theme.colorScheme.onSurfaceVariant,
          hasValue: color != null,
          onTap: () => _pickColor(context),
          onLongPress: color == null ? null : () => _setColor(context, null),
        ),
        if (showDate)
          _ClearableIcon(
            tooltip: !hasDate
                ? '日期：点一下选'
                : '日期 ${describeDateWithDays(project.date)}，点一下改或清',
            icon: hasDate ? Icons.event_available_outlined : Icons.event_outlined,
            color: overdue ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            hasValue: hasDate,
            onTap: () => _pickDate(context),
          ),
      ],
    );
  }

  Future<void> _pickColor(BuildContext context) async {
    final picked = await pickProjectColor(
      context,
      current: project.color,
      // 每支色被几个项目 / 分类 / 事件占着（画在色块右下角）
      usage: app.ws.markerColorUsage(),
    );
    // null = 取消；'' = 明确选了"不用标识色"
    if (picked == null || !context.mounted) return;
    _setColor(context, picked.isEmpty ? null : picked);
  }

  void _setColor(BuildContext context, String? value) {
    final error = app.run(() => app.ws.setProjectColor(project.id, value));
    if (error != null) showToast(context, error, error: true);
  }

  Future<void> _pickDate(BuildContext context) async {
    final picked = await pickDateSheet(
      context,
      title: project.date == null ? '选择日期' : '改日期',
      current: project.date,
    );
    if (picked == null || !context.mounted) return;
    // 空串 = 用户点了「清除日期」
    _setDate(context, picked == clearDateValue ? null : picked);
  }

  void _setDate(BuildContext context, String? value) {
    final error = app.run(() => app.ws.updateProject(project.id, date: value));
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, value == null ? '已清除日期' : '日期：$value');
  }
}

/// 一个"有值时长按可清除"的图标按钮：右下角一个小叉表示可以清掉。
class _ClearableIcon extends StatelessWidget {
  const _ClearableIcon({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.hasValue,
    required this.onTap,
    this.onLongPress,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final bool hasValue;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Icon(icon, size: 22, color: color),
              if (hasValue)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close,
                      size: 11,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一次「清除已完成条目」的**范围与代价**（确认框要用它说话）。
///
/// 范围与「重置」同一套：[resetScopeOf] 给的本级 + 所有**直属**下级，
/// 但这里只看**已勾选**的那些条目 —— 没做完的是还没交付的计划，
/// 批量动作误伤它们的代价远大于收益。
({int projects, int items}) clearDoneScopeOf(Project project, AppController app) {
  final scope = app.resetScopeOf(project.id);
  var projects = 0;
  var items = 0;
  for (final each in scope) {
    final done = each.items.where((item) => item.done).length;
    if (done == 0) continue;
    projects += 1;
    items += done;
  }
  return (projects: projects, items: items);
}

/// 一个带轻阴影的字段卡（项目详情里「有什么问题 / 思路 / 实现清单 / 如何解决 / 汇总」共用）。
///
/// 抽出来是为了让几块**长得一样**：以前「目的」是 `Card(elevation: 0)`
/// （其实没有阴影），清单与正文则是裸标题 + 内容 —— 同一页里三种观感。
///
/// `elevation` 取 1：要的是"轻微浮起"的层次，不是卡片式的大阴影。
class _FieldCard extends StatelessWidget {
  const _FieldCard({required this.title, this.trailing, required this.child});

  final String title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trailingWidget = trailing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  // 标题让位给右侧的进度 / 入口：`Row` 里的非弹性子节点拿的是
                  // **无界宽度**，标题若是纯 `Text`，右侧一宽就会整行溢出。
                  // 交给 `Expanded` + 省略号，窄屏 + 1.6 倍字体也压得住。
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (trailingWidget != null) ...<Widget>[
                    const SizedBox(width: 8),
                    trailingWidget,
                  ],
                ],
              ),
              const SizedBox(height: 4),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.title,
    required this.hint,
    required this.value,
    required this.onSubmitted,
  });

  final String title;
  final String hint;
  final String value;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _FieldCard(
      title: title,
      child: InlineTextField(
        value: value,
        hint: hint,
        minLines: 1,
        maxLines: 12,
        allowEmpty: true,
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.outline,
          fontStyle: FontStyle.italic,
        ),
        onSubmitted: onSubmitted,
      ),
    );
  }
}

/// 「下级」列表：**点一行就地展开**（ADR-070 / ADR-085），展开后按**整棵子树**
/// 递归铺开 —— 下级如果本身还是分类，就接着往下展，一直到最底层的目标，
/// 并列出那个目标的实现清单。
///
/// 为什么递归（2026-09-28 实机反馈："当分类的下级还有分类的时候在父分类对应的
/// 下拉菜单应当显示子分类所包含的项目，以此类推"）：在这一层要回答的是
/// "这个方向走到哪了"，而三层结构下"下级的清单"往往还挂在更深一层 ——
/// 从前展开只走一层，看到的是"这里还有一个分类"，等于没回答那个问题。
///
/// 每层缩进一档（每档 20dp），最底层的目标是叶子：列出它的清单条目，可勾。
/// 完整字段（问题 / 思路、如何解决、灵感）仍旧在下级自己的详情页里 ——
/// 点那一行的标题进去。
class _ChildrenField extends StatefulWidget {
  const _ChildrenField({required this.app, required this.project, required this.children});

  final AppController app;
  final Project project;
  final List<Project> children;

  @override
  State<_ChildrenField> createState() => _ChildrenFieldState();
}

class _ChildrenFieldState extends State<_ChildrenField> {
  /// 每往下一层的缩进（dp）。
  static const double _indentPerLevel = 20;

  /// 已展开的下级（按 id 记）。勾一条清单就会触发整页重建，
  /// 展开状态不能挂在临时变量上，否则勾一下就自己收起来了。
  final Set<String> _expanded = <String>{};

  AppController get app => widget.app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = widget.children;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 下级区整体收在左边距 16 的一条线上，与上面的字段卡左缘对齐；
        // 条目行本身再往里缩，用"缩进"而不是"大间距"表达它是下级。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Row(
            children: <Widget>[
              Text('下级', style: theme.textTheme.labelLarge),
              const SizedBox(width: 6),
              Text('${children.length}', style: theme.textTheme.labelSmall),
            ],
          ),
        ),
        for (final child in children) ..._subtree(child, 0),
        // 新建下级：文案随层级走（Q2）—— 在**分类**下新建的是「目标」。
        // 用现成的 `InlineComposer`，不新增控件；放在下级列表**末尾**
        // （与「实现清单」的「添加条目」同一个位置习惯）。
        //
        // 刻意**不**塞进上面那一行标题 `Row` 里：`InlineComposer` 展开后内部是
        // `Row + Expanded`，而 `Row` 里的非弹性子节点拿到的是**无界宽度**，
        // 一展开就会抛 "non-zero flex but incoming width constraints are unbounded"。
        InlineComposer(
          label: '新建目标',
          hint: '目标名',
          leading: Icons.add,
          dense: true,
          onCreate: (title) {
            final error = app.run(
              () => app.ws.createProject(title: title, parentId: widget.project.id),
            );
            if (error != null) showToast(context, error, error: true);
          },
        ),
      ],
    );
  }

  /// 一个节点连同它的展开区（递归）。
  ///
  /// [depth] 从 0 起：本级的下级是 0，再下一层是 1。
  List<Widget> _subtree(Project node, int depth) {
    final children = app.ws.childProjectsOf(node.id);
    // 还能不能再往下：先看**结构**上有没有下一层（`depth + 2` 才是这一层的深度
    // —— `depthOf` 把根算作 1），再看有没有子节点。
    final canNest = depth + 2 < maxProjectDepth && children.isNotEmpty;
    final expanded = _expanded.contains(node.id);

    return <Widget>[
      _ChildRow(
        key: ValueKey<String>('child-${node.id}'),
        child: node,
        depth: depth,
        expanded: expanded,
        // 叶子（最底层的目标）没有可展开的东西，不给箭头
        collapsible: canNest,
        onToggle: () => setState(() {
          if (!_expanded.remove(node.id)) _expanded.add(node.id);
        }),
        onOpen: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ProjectDetailPage(app: app, projectId: node.id),
          ),
        ),
      ),
      // 展开区**长出来**而不是啪地出现（2026-09-28 实机反馈：所有展开 / 收起
      // 动作都要有动画）——递归的每一层都各自有这一段，所以整棵子树都是顺的。
      //
      // 壳**始终在树上**（不能写 `if (expanded)`）：写成条件渲染的话，展开时
      // 这个控件是"新挂上来"的，`AnimatedCollapse` 拿不到从收起变展开那次变化，
      // 动画根本不会播。
      AnimatedCollapse(
        expanded: expanded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (canNest)
              for (final grand in children) ..._subtree(grand, depth + 1)
            else if (node.items.isNotEmpty)
              _ChildChecklist(
                app: app,
                child: node,
                depth: depth,
                indentPerLevel: _indentPerLevel,
              ),
            if (!canNest && node.items.isEmpty)
              _ChildEmptyHint(depth: depth, indentPerLevel: _indentPerLevel),
          ],
        ),
      ),
    ];
  }
}

/// 一行下级：**点它进下级自己的详情页**，**行尾箭头**只管展开 / 收起。
///
/// （2026-09-27 实机反馈：分类详情页展开之后，去掉「添加条目」与「打开项目」
///   两项。）展开区里原来那个「打开这个目标」按钮跟着一起去掉了，
/// 所以"怎么进下级"必须另有出路 —— 就是点这一行的**标题**。
/// 与"点箭头只折叠"分开之后，一行上有两个各管一件事的落点：
///
/// ```
/// ● 发布 v1            ← 点这里进详情页
///   清单 1/2        ⌄  ← 点这里只展开 / 收起
/// ```
class _ChildRow extends StatelessWidget {
  const _ChildRow({
    super.key,
    required this.child,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
    this.depth = 0,
    this.collapsible = true,
  });

  final Project child;
  final bool expanded;
  final VoidCallback onToggle;

  /// 进下级自己的详情页。
  final VoidCallback onOpen;

  /// 第几层（0 = 本级的下级）。每层多缩进 20dp。
  final int depth;

  /// 还有没有下一层可展。**叶子（最底层的目标）不给箭头** ——
  /// 一个点了没反应的箭头比没有箭头更糟。
  final bool collapsible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = _childSubtitle(theme, child);
    return Padding(
      // 比主项目行更紧凑：缩进表达层级，字号降一档
      padding: EdgeInsets.fromLTRB(24.0 + depth * 20, 6, 12, 6),
      child: Row(
        children: <Widget>[
          ProjectMarker(color: child.color, size: 12),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(AppShapes.chipRadius),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(child.title, style: theme.textTheme.bodyMedium),
                    ?subtitle,
                  ],
                ),
              ),
            ),
          ),
          // 折叠开关只占行尾这一小块：点它**只**折叠，不进详情页
          IconButton(
            tooltip: expanded ? '收起' : '展开',
            onPressed: onToggle,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: const Icon(Icons.chevron_right),
            ),
          ),
        ],
      ),
    );
  }
}

/// 展开后的**实现清单**：就地打勾。
///
/// 打勾的口径与项目页一致（`ProjectChecklist`）：**只是打勾，不参与任何判定**，
/// 全勾完也不会把项目变成已完成（项目没有完成态，见 Q1）。
///
/// 这里**只能勾**（2026-09-27 实机反馈：去掉「添加条目」与「打开这个目标」）。
/// 改字、加条目、删条目、上移下移、建成任务都留在下级自己的详情页
/// —— 一个展开区里塞两套操作，用户在分类页就分不清自己在改哪一层。
class _ChildChecklist extends StatelessWidget {
  const _ChildChecklist({
    required this.app,
    required this.child,
    this.depth = 0,
    this.indentPerLevel = 20,
  });

  final AppController app;
  final Project child;

  /// 这一批条目所属目标在第几层（与 `_ChildRow` 的 depth 同一套）。
  final int depth;
  final double indentPerLevel;

  @override
  Widget build(BuildContext context) {
    // 一条都没有就不占位（`_ChildrenField` 会补一句提示）
    if (child.items.isEmpty) return const SizedBox.shrink();
    // 缩进对齐上级那一行的标题文字（24 缩进 + 12 标识色 + 12 间距 = 48），
    // 再按层级往下让
    return Padding(
      padding: EdgeInsets.fromLTRB(40 + depth * indentPerLevel, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final item in child.items)
            _RoundCheckRow(
              done: item.done,
              text: item.text,
              onChanged: (value) => _setDone(context, item.id, value),
            ),
        ],
      ),
    );
  }

  void _setDone(BuildContext context, String itemId, bool value) =>
      _run(context, () => app.ws.setProjectItemDone(child.id, itemId, value));

  void _run(BuildContext context, void Function() action) {
    final error = app.run(action);
    if (error != null && context.mounted) showToast(context, error, error: true);
  }
}

/// 展到底层的目标却一条条目都没有时的一句话。
///
/// 加了递归之后这是**常见**情况（三层结构里最底下那层还没开工），
/// 什么都不画会让人以为"展开坏了"。
class _ChildEmptyHint extends StatelessWidget {
  const _ChildEmptyHint({required this.depth, required this.indentPerLevel});

  final int depth;
  final double indentPerLevel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(40 + depth * indentPerLevel, 0, 12, 6),
      child: Text('还没有条目', style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// 一条**圆形**勾选行（分类展开区用）。
///
/// 为什么是圆的而项目页的清单是方的：这里是"下级目标里的一条"，
/// 点到的是**别人的**清单（实机反馈：确认框改成圆形）—— 形状不同，
/// 一眼就知道自己不在改自己那一层。方块/圆块的区分比再加一行说明省地方。
class _RoundCheckRow extends StatelessWidget {
  const _RoundCheckRow({
    required this.done,
    required this.text,
    required this.onChanged,
  });

  final bool done;
  final String text;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => onChanged(!done),
      borderRadius: BorderRadius.circular(AppShapes.chipRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // 圆形勾选：选中画对勾、未选中画空心圈，与方形的 `Checkbox` 区分开
            Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: done ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: done
                    ? theme.textTheme.bodySmall?.copyWith(
                        decoration: TextDecoration.lineThrough,
                        color: theme.colorScheme.outline,
                      )
                    : theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 下级项目行的副标题：**一行搞定**，没有内容就整行不显示。
///
/// 只放两个"一眼能做决定"的数字与记号：清单进度（决定要不要展开）与日期。
/// 原来固定写「未设置日期」，每条都多一行字，既占地方又没信息量；
/// 现在项目也没有状态可写（Q1），所以这里只剩这两项。
///
/// 私有（Q41）：全仓只有这一页的下级行用它，公开出去只是给"零调用"留口子。
Text? _childSubtitle(ThemeData theme, Project child) {
  final parts = <String>[
    if (child.items.isNotEmpty) '清单 ${child.itemsDoneCount}/${child.items.length}',
    if (child.date != null) describeDate(child.date),
  ];
  if (parts.isEmpty) return null;
  return Text(
    parts.join(' · '),
    style: theme.textTheme.labelSmall,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

/// 项目详情页的「待处理灵感」。
///
/// 点一条**直接进合并编辑器**（入口在项目侧，不用绕回灵感页）；
/// **长按进多选**（2026-09-28 实机反馈："项目界面的待处理灵感也应当可以长按多选"），
/// 动作条与批量动作跟灵感页**共用同一份**（`inspiration_selection.dart`）——
/// 两处各写一套，"批量丢弃到底进不进归档区"这种口径迟早会漂。
class _InspirationsField extends StatefulWidget {
  const _InspirationsField({
    required this.app,
    required this.project,
    required this.inspirations,
  });

  final AppController app;
  final Project project;
  final List<Inspiration> inspirations;

  @override
  State<_InspirationsField> createState() => _InspirationsFieldState();
}

class _InspirationsFieldState extends State<_InspirationsField> {
  bool _selecting = false;
  final Set<String> _selectedIds = <String>{};

  AppController get app => widget.app;

  void _enterSelection(String id) {
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(id);
    });
  }

  void _exitSelection() {
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == widget.inspirations.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(widget.inspirations.map((each) => each.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inspirations = widget.inspirations;
    // 选中项可能在别处被改掉了（例如在灵感页合并走），每次构建清一遍幽灵选中
    _selectedIds.removeWhere((id) => !inspirations.any((each) => each.id == id));

    final actions = InspirationBatchActions(
      app: app,
      selectedIds: _selectedIds.toList(growable: false),
      onDone: _exitSelection,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Row(
            children: <Widget>[
              Text(
                _selecting ? '已选 ${_selectedIds.length} 条' : '待处理灵感 ${inspirations.length}',
                style: theme.textTheme.labelLarge,
              ),
            ],
          ),
        ),
        // 多选动作条**滑出来**（2026-09-28 实机反馈：多选时切换要流畅）
        AnimatedCollapse(
          expanded: _selecting,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: InspirationSelectionBar(
              selectedCount: _selectedIds.length,
              allSelected: inspirations.isNotEmpty &&
                  _selectedIds.length == inspirations.length,
              canSelectAll: inspirations.isNotEmpty,
              onToggleAll: _toggleSelectAll,
              onExit: _exitSelection,
              onAssign: () => actions.assign(context),
              onMerge: () => actions.merge(context, inspirations),
              onDiscard: () => actions.discard(context),
              onDelete: () => actions.delete(context),
            ),
          ),
        ),
        if (inspirations.isNotEmpty)
          // 点一条**直接进合并编辑器**（多选态下点它只切换选中）。
          // 原来这里是只读列表，还让用户"去灵感页合并"——入口绕了一圈。
          for (final inspiration in inspirations)
            ListTile(
              dense: true,
              // 多选时行首换个**圆形**勾选记号（与动作条、分类页展开区同一个形状，
              // 不再是方形 Checkbox）
              leading: _selecting
                  ? Icon(
                      _selectedIds.contains(inspiration.id)
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: _selectedIds.contains(inspiration.id)
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    )
                  : const Icon(Icons.lightbulb_outline, size: 18),
              title: Text(inspiration.text, maxLines: 3, overflow: TextOverflow.ellipsis),
              subtitle: Text(relativeTime(inspiration.createdAt), style: theme.textTheme.labelSmall),
              trailing: _selecting ? null : const Icon(Icons.merge_type, size: 18),
              selected: _selecting && _selectedIds.contains(inspiration.id),
              onTap: _selecting
                  ? () => _toggleSelection(inspiration.id)
                  : () => _merge(context, inspiration),
              // 长按进多选；已经在多选里就直接切换（与灵感页同一套习惯）
              onLongPress: _selecting
                  ? () => _toggleSelection(inspiration.id)
                  : () => _enterSelection(inspiration.id),
            ),
      ],
    );
  }

  /// 与灵感页走的是同一个 `MergeEditorPage`（三种选择都在那一页里），
  /// 只是入口在项目侧。
  Future<void> _merge(BuildContext context, Inspiration inspiration) async {
    final result = await Navigator.of(context).push<MergeResult>(
      MaterialPageRoute<MergeResult>(
        builder: (_) => MergeEditorPage(project: widget.project, inspiration: inspiration),
      ),
    );
    if (result == null || !context.mounted) return;
    await applyMergeResult(context, app, widget.project, inspiration, result);
  }
}
