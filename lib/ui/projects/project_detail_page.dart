import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/rules/handoff_export.dart';
import '../../features/workspace.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import '../common/status_selector.dart';
import '../inspiration/merge_editor_page.dart';
import '../theme/shape_tokens.dart';
import 'handoff_preview_page.dart';
import 'project_actions.dart';
import 'project_checklist.dart';

/// 项目详情：**目的 / 实现 / 日期 / 三态**，加子项目与已分配灵感。
///
/// 「实现」分成两块：上面的**待办清单**（结构化、可勾选）与下面的
/// **实现计划**（整段说明 / AI 整理的输出）。
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
        final children = ws.projectTree
            .childrenOf(widget.projectId)
            .whereType<Project>()
            .where((p) => !p.archived)
            .toList(growable: false);
        final inspirations = ws.liveInspirations
            .where((i) => i.isPending && i.projectId == widget.projectId)
            .toList(growable: false)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

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
                            await moveProjectAction(context, app, project.id);
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
                      itemBuilder: (_) => const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
                        PopupMenuItem<String>(
                          value: 'handoff',
                          child: Text('导出交接说明…'),
                        ),
                        PopupMenuItem<String>(value: 'move', child: Text('移动到…')),
                        PopupMenuItem<String>(value: 'archive', child: Text('归档')),
                        PopupMenuItem<String>(value: 'delete', child: Text('删除')),
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
              _StatusField(app: app, project: project),
              _TextField(
                title: '目的',
                hint: '为什么做这个项目',
                value: project.purpose,
                onSubmitted: (value) =>
                    app.run(() => ws.updateProject(project.id, purpose: value)),
              ),
              // 「实现」由两部分组成：上面的**待办清单**（结构化、可勾选），
              // 下面的**实现计划**（整段说明 / 灵感合并的落点 / AI 整理的输出）。
              // 两者都套在与「目的」同一个 `_FieldCard` 里，一页只留一种观感。
              _FieldCard(
                title: '实现清单',
                trailing: project.items.isEmpty
                    ? null
                    : Text(
                        '${project.itemsDoneCount}/${project.items.length}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                child: ProjectChecklist(
                  app: app,
                  project: project,
                  onSplitFromImplementation: () => _splitIntoItems(context, project),
                ),
              ),
              _FieldCard(
                title: '实现计划',
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
        message: '会先清空现在这 ${project.items.length} 条，再按正文重新拆成 ${lines.length} 条。\n'
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
    if (context.mounted) showToast(context, '已拆成 ${lines.length} 条');
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

/// 「实现计划」的**内容部分**（标题与卡片外壳由 `_FieldCard` 负责）。
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
      hint: '怎么做 —— 灵感合并、AI 整理都会写到这里',
      minLines: 1,
      maxLines: 12,
      allowEmpty: true,
      textStyle: theme.textTheme.bodyMedium,
      onSubmitted: widget.onSubmit,
    );
  }
}

/// 状态 + 标识色 / 日期图标。三样都是"这个项目本身"的属性，所以放在同一行。
class _StatusField extends StatelessWidget {
  const _StatusField({required this.app, required this.project});

  final AppController app;
  final Project project;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('状态', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              _IconActions(app: app, project: project),
            ],
          ),
          const SizedBox(height: 8),
          StatusPillSelector<NodeStatus>(
            values: NodeStatus.values,
            selected: project.status,
            labelOf: nodeStatusLabel,
            onSelected: (status) {
              final error = app.run(() => app.ws.setProjectStatus(project.id, status));
              if (error != null) showToast(context, error, error: true);
            },
          ),
        ],
      ),
    );
  }
}

/// 「标识色 / 日期」的图标入口。
///
/// 按实机反馈收成图标：这两项是**设置一次就不再动**的东西，
/// 各占一整行 ListTile 太浪费纵向空间。长按 = 清除（图标右下角带个小叉提示），
/// 所以不需要再各配一个"清除"按钮。
class _IconActions extends StatelessWidget {
  const _IconActions({required this.app, required this.project});

  final AppController app;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = colorOfHex(project.color);
    final hasDate = project.date != null;
    final overdue = hasDate && isOverdue(project.date) && project.status != NodeStatus.done;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ClearableIcon(
          tooltip: color == null
              ? '标识色：点一下选'
              : '标识色 ${project.color}（长按清除）',
          icon: Icons.palette_outlined,
          color: color ?? theme.colorScheme.onSurfaceVariant,
          hasValue: color != null,
          onTap: () => _pickColor(context),
          onLongPress: color == null ? null : () => _setColor(context, null),
        ),
        _ClearableIcon(
          tooltip: !hasDate
              ? '日期：点一下选'
              : '日期 ${describeDateWithDays(project.date)}（长按清除）',
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

/// 一个"带轻阴影的字段卡"（项目详情里「目的 / 实现清单 / 实现计划」共用）。
///
/// 抽出来是为了让三块**长得一样**：以前「目的」是 `Card(elevation: 0)`
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
                  Text(title, style: theme.textTheme.labelLarge),
                  const Spacer(),
                  ?trailing,
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

class _ChildrenField extends StatelessWidget {
  const _ChildrenField({required this.app, required this.project, required this.children});

  final AppController app;
  final Project project;
  final List<Project> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 子项目区整体收在左边距 16 的一条线上，与上面的字段卡左缘对齐；
        // 条目行本身再往里缩 8，用"缩进"而不是"大间距"表达它是下级。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Row(
            children: <Widget>[
              Text('子项目', style: theme.textTheme.labelLarge),
              const SizedBox(width: 6),
              Text('${children.length}', style: theme.textTheme.labelSmall),
              const Spacer(),
              // 新建子项目：一个加号（按实机反馈），不再是占一整行文字的入口
              _AddChildButton(
                onCreate: (title) {
                  final error = app.run(
                    () => app.ws.createProject(title: title, parentId: project.id),
                  );
                  if (error != null) showToast(context, error, error: true);
                },
              ),
            ],
          ),
        ),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('还没有子项目', style: theme.textTheme.bodySmall),
          )
        else
          for (final child in children)
            // 比主项目行更紧凑：小图标 + 小字号 + 一行式副标题，
            // 缩进 24 表达层级（`contentPadding` 同时收紧到 8，
            // 原来是 `ListTile` 默认的 16 + 20 图标位，显得空）
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.only(left: 24, right: 12),
              minLeadingWidth: 18,
              leading: ProjectMarker(color: child.color, size: 12),
              title: Text(child.title, style: theme.textTheme.bodyMedium),
              subtitle: childSubtitle(theme, child),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => ProjectDetailPage(app: app, projectId: child.id),
                ),
              ),
            ),
      ],
    );
  }
}

/// 子项目行的副标题：**一行搞定**（日期或状态），没有就不显示。
///
/// 原来固定写「未设置日期」，每条都多一行字，既占地方又没信息量。
Text? childSubtitle(ThemeData theme, Project child) {
  if (child.date != null) {
    return Text(
      describeDate(child.date),
      style: theme.textTheme.labelSmall,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
  final status = nodeStatusLabel(child.status);
  if (status.isEmpty) return null;
  return Text(status, style: theme.textTheme.labelSmall);
}

/// 「新建子项目」的加号按钮：点一下旁边就展开输入框。
class _AddChildButton extends StatefulWidget {
  const _AddChildButton({required this.onCreate});

  final ValueChanged<String> onCreate;

  @override
  State<_AddChildButton> createState() => _AddChildButtonState();
}

class _AddChildButtonState extends State<_AddChildButton> {
  bool _editing = false;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) widget.onCreate(text);
    _controller.clear();
    // 保持展开，方便连着建几个
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return IconButton.filledTonal(
        tooltip: '新建子项目',
        icon: const Icon(Icons.add, size: 20),
        visualDensity: VisualDensity.compact,
        onPressed: () {
          setState(() => _editing = true);
          _focus.requestFocus();
        },
      );
    }
    return SizedBox(
      width: 200,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          isDense: true,
          hintText: '子项目名',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppShapes.cardRadius),
          ),
          suffixIcon: IconButton(
            tooltip: '收起',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _editing = false),
          ),
        ),
      ),
    );
  }
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
        if (inspirations.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('这个项目下没有待处理灵感', style: theme.textTheme.bodySmall),
          )
        else ...<Widget>[
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '点一条即可把它并进「实现计划」，或直接追加成清单的一条',
              style: theme.textTheme.bodySmall,
            ),
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
