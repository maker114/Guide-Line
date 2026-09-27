import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/rules/handoff_export.dart';
import '../../features/workspace.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../inspiration/merge_editor_page.dart';
import '../theme/shape_tokens.dart';
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
                        // 分类不写「有什么问题 / 思路」，也没有清单与如何解决，
                        // 交接说明对它没有意义 —— 这个入口只给目标。
                        if (!isCategory)
                          const PopupMenuItem<String>(
                            value: 'handoff',
                            child: Text('导出交接说明…'),
                          ),
                        PopupMenuItem<String>(
                          value: 'move',
                          child: Text(isCategory ? '移到其它分类' : '移动到…'),
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
                _ProjectIconsRow(app: app, project: project, showDate: false),
                _TextField(
                  title: '总纲领',
                  hint: '这一类要一起往哪走',
                  value: project.purpose,
                  onSubmitted: (value) =>
                      app.run(() => ws.updateProject(project.id, purpose: value)),
                ),
                _ChildrenField(app: app, project: project, children: children),
              ] else ...<Widget>[
                _ProjectIconsRow(app: app, project: project),
                _TextField(
                  title: '有什么问题 / 思路',
                  hint: '想解决什么问题、有什么思路',
                  value: project.purpose,
                  onSubmitted: (value) =>
                      app.run(() => ws.updateProject(project.id, purpose: value)),
                ),
                // 「实现」由两部分组成：上面的**实现清单**（结构化、可勾选），
                // 下面的**如何解决**（整段说明 / 灵感合并的落点 / AI 整理的输出）。
                // 两者都套在与「有什么问题 / 思路」同一个 `_FieldCard` 里，一页只留一种观感。
                _FieldCard(
                  title: '实现清单',
                  // 进度与「重拆 / 清空」入口共用标题行右侧（Q32）：
                  // 一个数字 + 一枚胶囊，加起来比原来那个"独占一整行的更多按钮"省地方。
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (project.items.isNotEmpty) ...<Widget>[
                        Text(
                          '${project.itemsDoneCount}/${project.items.length}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(width: 8),
                      ],
                      // 清空 / 按正文重拆这两件事平时不用，但"拆错了想重来"时
                      // 必须找得到 —— 上一批把它们藏进长按里，用户就再也看不到了。
                      Tooltip(
                        message: '清单：按正文重拆 / 清空',
                        child: TextButton.icon(
                          onPressed: () => _showChecklistActions(context, project),
                          icon: const Icon(Icons.tune, size: 18),
                          label: const Text('重拆 / 清空'),
                          style: TextButton.styleFrom(
                            // 能点的用胶囊（《界面规范》§1）；次要入口不加底色
                            shape: AppShapes.pill,
                            // 不用强调色：这里进去的是**危险动作**（清空 / 覆盖现有条目），
                            // 规范要求危险动作别做成醒目的按钮，实际的门在确认框上
                            foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ],
                  ),
                  child: ProjectChecklist(
                    app: app,
                    project: project,
                    onSplitFromImplementation: () => _splitIntoItems(context, project),
                  ),
                ),
                _FieldCard(
                  title: '如何解决',
                  child: _ImplementationBody(
                    value: project.implementation,
                    hasItems: project.items.isNotEmpty,
                    onSubmit: (value) {
                      // AI 整理后正文会被替换，空内容会被业务层拒绝（不让正文被清没）
                      if (value.trim().isEmpty) return;
                      final error = app.run(() => ws.replaceImplementation(project.id, value));
                      if (error != null) showToast(context, error, error: true);
                    },
                  ),
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

  /// 生成并把用户送到**交接说明预览页**（真正写文件在那一步）。
  Future<void> _exportHandoff(BuildContext context, Project project) async {
    final markdown = HandoffExport.build(
      project: project,
      // 只带这个项目的待处理灵感 —— 事件与任务线不再进交接说明（实机反馈：
      // 事件与项目没有关联字段，全量带过去只会把说明撑长、跑题）
      inspirations: app.ws.liveInspirations
          .where((i) => i.projectId == project.id)
          .toList(growable: false),
      now: DateTime.now(),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HandoffPreviewPage(
          app: app,
          projectId: project.id,
          projectTitle: project.title,
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

/// 「如何解决」的**内容部分**（标题与卡片外壳由 `_FieldCard` 负责）。
///
/// 这一块是三样东西的共同落点 —— AI 整理写进来、交接导出从这里取、
/// 手写也写在这里（灵感合并不再写它，见 `Workspace.mergeInspiration`）。
/// 清单为空时它就是主角，默认展开；有清单时它退成"整理稿"，默认收起，
/// 免得一屏全是字。
class _ImplementationBody extends StatefulWidget {
  const _ImplementationBody({
    required this.value,
    required this.hasItems,
    required this.onSubmit,
  });

  final String value;
  final bool hasItems;
  final ValueChanged<String> onSubmit;

  @override
  State<_ImplementationBody> createState() => _ImplementationBodyState();
}

class _ImplementationBodyState extends State<_ImplementationBody> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = widget.value;
    final empty = value.trim().isEmpty;
    final canCollapse = !empty && widget.hasItems;
    final showEditor = !canCollapse || _expanded;

    if (!canCollapse) {
      return _editor(theme, value);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('${value.trim().length} 字', style: theme.textTheme.labelSmall),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
              label: Text(_expanded ? '收起' : '展开'),
            ),
          ],
        ),
        if (showEditor) _editor(theme, value),
      ],
    );
  }

  Widget _editor(ThemeData theme, String value) {
    return InlineTextField(
      value: value,
      hint: '打算怎么做',
      minLines: 1,
      maxLines: 12,
      allowEmpty: true,
      textStyle: theme.textTheme.bodyMedium,
      onSubmitted: widget.onSubmit,
    );
  }
}

/// 「标识色 / 日期」的图标入口。
///
/// 这一行原来是「状态」那一行 —— 项目取消完成 / 搁置之后（Q1），三态胶囊整个拿掉，
/// 只留下这两个"设置一次就不再动"的图标。
class _ProjectIconsRow extends StatelessWidget {
  const _ProjectIconsRow({
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _IconActions(app: app, project: project, showDate: showDate),
      ),
    );
  }
}

/// 「标识色 / 日期」的图标入口。
///
/// 按实机反馈收成图标：这两项是**设置一次就不再动**的东西，
/// 各占一整行 ListTile 太浪费纵向空间。长按 = 清除（图标右下角带个小叉提示），
/// 所以不需要再各配一个"清除"按钮。分类只给标识色（分类没有日期，见 Q2）。
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
                : '日期 ${describeDateWithDays(project.date)}，长按可清除',
            icon: hasDate ? Icons.event_available_outlined : Icons.event_outlined,
            color: overdue ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            hasValue: hasDate,
            onTap: () => _pickDate(context),
            onLongPress: hasDate ? () => _setDate(context, null) : null,
          ),
      ],
    );
  }

  Future<void> _pickColor(BuildContext context) async {
    final picked = await pickProjectColor(context, current: project.color);
    // null = 取消；'' = 明确选了"不用标识色"
    if (picked == null || !context.mounted) return;
    _setColor(context, picked.isEmpty ? null : picked);
  }

  void _setColor(BuildContext context, String? value) {
    final error = app.run(() => app.ws.setProjectColor(project.id, value));
    if (error != null) showToast(context, error, error: true);
  }

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final initial = project.date == null ? now : (DateTime.tryParse(project.date!) ?? now);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
      helpText: project.date == null ? '选择日期' : '当前：${describeDateWithDays(project.date)}',
    );
    if (picked == null || !context.mounted) return;
    final month = picked.month.toString().padLeft(2, '0');
    final day = picked.day.toString().padLeft(2, '0');
    _setDate(context, '${picked.year}-$month-$day');
  }

  void _setDate(BuildContext context, String? value) {
    final error = app.run(() => app.ws.updateProject(project.id, date: value));
    if (error != null) showToast(context, error, error: true);
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

/// 一个"带轻阴影的字段卡"（项目详情里「有什么问题 / 思路 / 实现清单 / 如何解决 / 汇总」共用）。
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

/// 「下级」列表：**点一行就地展开**（ADR-070），展开后直接看到并勾选
/// 那个下级的实现清单。
///
/// 分类里装的是同一个方向上的几件事（Q2）：在这一层要回答的是"这个方向走到哪了"，
/// 所以一行下级只给三样东西 —— 名字、进度 `清单 n/m`、展开后的清单本体。
/// 完整字段（问题 / 思路、如何解决、灵感）仍旧在下级自己的详情页里，
/// 入口放在展开区的最后一步（「打开这个目标」）。
class _ChildrenField extends StatefulWidget {
  const _ChildrenField({required this.app, required this.project, required this.children});

  final AppController app;
  final Project project;
  final List<Project> children;

  @override
  State<_ChildrenField> createState() => _ChildrenFieldState();
}

class _ChildrenFieldState extends State<_ChildrenField> {
  /// 已展开的下级（按 id 记）。勾一条清单就会触发整页重建，
  /// 展开状态不能挂在临时变量上，否则勾一下就自己收起来了。
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = widget.children;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 下级区整体收在左边距 16 的一条线上，与上面的字段卡左缘对齐；
        // 条目行本身再往里缩 8，用"缩进"而不是"大间距"表达它是下级。
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
        if (children.isNotEmpty)
          for (final child in children) ...<Widget>[
            _ChildRow(
              key: ValueKey<String>(child.id),
              child: child,
              expanded: _expanded.contains(child.id),
              onToggle: () => setState(() {
                // `remove` 返回 false = 原本没展开，那就展开
                if (!_expanded.remove(child.id)) _expanded.add(child.id);
              }),
            ),
            if (_expanded.contains(child.id))
              _ChildChecklist(
                app: widget.app,
                child: child,
                onOpen: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ProjectDetailPage(
                      app: widget.app,
                      projectId: child.id,
                    ),
                  ),
                ),
              ),
          ],
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
            final error = widget.app.run(
              () => widget.app.ws.createProject(title: title, parentId: widget.project.id),
            );
            if (error != null) showToast(context, error, error: true);
          },
        ),
      ],
    );
  }
}

/// 一行下级：**点它就展开 / 收起**。
///
/// 展开方向只用一个记号表示（行尾的 `chevron_right` 转到朝下），
/// 进详情页的入口放在展开区里 —— 一行上挂两个"点我"的记号只会让人犹豫。
class _ChildRow extends StatelessWidget {
  const _ChildRow({
    super.key,
    required this.child,
    required this.expanded,
    required this.onToggle,
  });

  final Project child;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = _childSubtitle(theme, child);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        // 比主项目行更紧凑：缩进 24 表达层级，字号降一档
        padding: const EdgeInsets.fromLTRB(24, 6, 12, 6),
        child: Row(
          children: <Widget>[
            ProjectMarker(color: child.color, size: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(child.title, style: theme.textTheme.bodyMedium),
                  ?subtitle,
                ],
              ),
            ),
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: const Icon(Icons.chevron_right, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// 展开后的**实现清单**：就地打勾。
///
/// 打勾的口径与项目页一致（`ProjectChecklist`）：**只是打勾，不参与任何判定**，
/// 全勾完也不会把项目变成已完成（项目没有完成态，见 Q1）。
///
/// 这里**只**能勾和加：改字、删条目、上移下移、建成任务都留在下级自己的详情页
/// —— 一个展开区里塞两套操作，用户在分类页就分不清自己在改哪一层了。
class _ChildChecklist extends StatelessWidget {
  const _ChildChecklist({
    required this.app,
    required this.child,
    required this.onOpen,
  });

  final AppController app;
  final Project child;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 缩进对齐上级那一行的标题文字（24 缩进 + 12 标识色 + 12 间距 = 48）
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final item in child.items)
            CheckboxListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: item.done,
              onChanged: (value) => _setDone(context, item.id, value ?? false),
              title: Text(
                item.text,
                style: item.done
                    ? theme.textTheme.bodySmall?.copyWith(
                        decoration: TextDecoration.lineThrough,
                        color: theme.colorScheme.outline,
                      )
                    : theme.textTheme.bodySmall,
              ),
            ),
          InlineComposer(
            label: '添加条目',
            hint: '这条要做什么',
            leading: Icons.add,
            dense: true,
            onCreate: (text) => _run(context, () => app.ws.addProjectItem(child.id, text)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('打开这个目标'),
              style: TextButton.styleFrom(
                shape: AppShapes.pill,
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
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

class _InspirationsField extends StatelessWidget {
  const _InspirationsField({
    required this.app,
    required this.project,
    required this.inspirations,
  });

  final AppController app;
  final Project project;
  final List<Inspiration> inspirations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Text('待处理灵感 ${inspirations.length}', style: theme.textTheme.labelLarge),
        ),
        if (inspirations.isNotEmpty) ...<Widget>[
          // 点一条**直接进合并编辑器**（灵感整理第 9 条）。
          // 原来这里是只读列表，还让用户"去灵感页合并"——入口绕了一圈。
          for (final inspiration in inspirations)
            ListTile(
              dense: true,
              leading: const Icon(Icons.lightbulb_outline, size: 18),
              title: Text(inspiration.text, maxLines: 3, overflow: TextOverflow.ellipsis),
              subtitle: Text(relativeTime(inspiration.createdAt), style: theme.textTheme.labelSmall),
              trailing: const Icon(Icons.merge_type, size: 18),
              onTap: () => _merge(context, inspiration),
            ),
        ],
      ],
    );
  }

  /// 与灵感页走的是同一个 `MergeEditorPage`（三种选择都在那一页里），
  /// 只是入口在项目侧。
  Future<void> _merge(BuildContext context, Inspiration inspiration) async {
    final result = await Navigator.of(context).push<MergeResult>(
      MaterialPageRoute<MergeResult>(
        builder: (_) => MergeEditorPage(project: project, inspiration: inspiration),
      ),
    );
    if (result == null || !context.mounted) return;
    await applyMergeResult(context, app, project, inspiration, result);
  }
}
