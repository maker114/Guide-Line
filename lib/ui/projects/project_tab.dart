import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/project.dart';
import '../common/color_picker.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import '../common/labels.dart';
import 'project_actions.dart';
import 'project_detail_page.dart';

/// 展开 / 收起箭头的旋转时长（项目页与事件页共用同一个节奏）。
const Duration _foldDuration = Duration(milliseconds: 180);

/// 项目 Tab：**项目树（≤ 3 层）**。
///
/// 手机上没有树控件的余地，所以用「扁平化 + 缩进 + 展开箭头」渲染：
/// 折叠状态存在 `UiPrefs` 里，下次进来还是原样。
///
/// 新建与重命名都是**页面内直接输入**（见 `InlineComposer` / `InlineTextField`）：
/// 点一下原地变成输入框，不再弹对话框。
class ProjectTab extends StatefulWidget {
  const ProjectTab({super.key, required this.app});

  final AppController app;

  @override
  State<ProjectTab> createState() => _ProjectTabState();
}

class _ProjectTabState extends State<ProjectTab> {
  /// 正在重命名的项目 id
  String? _renamingId;

  /// 正在为哪个项目录子项目
  String? _addingChildOf;

  AppController get _app => widget.app;

  void _create({String? parentId, required String title}) {
    final error = _app.run(
      () => _app.ws.createProject(title: title, parentId: parentId),
    );
    if (error != null) {
      _toast(error, error: true);
      return;
    }
    // 加完子项目就把那一行的输入框收起来，避免列表里挂着一排展开的输入
    if (parentId != null) setState(() => _addingChildOf = null);
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? Theme.of(context).colorScheme.errorContainer
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _flatten(_app);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            rows.isEmpty ? '还没有项目' : '共 ${rows.length} 个项目',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: <Widget>[
              InlineComposer(
                label: '新建项目',
                hint: '项目名',
                leading: Icons.create_new_folder_outlined,
                onCreate: (title) => _create(title: title),
              ),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '项目是「目的 + 实现」的容器，灵感可以合并进项目正文',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                // **每个主项目一张卡**（与设置页分组卡同一种观感）：
                //   · 一张卡里的多行靠"同框"表达归属，不再画分割线
                //     （分割线会把主项目与它的子项目切成同级的小块）；
                //   · 卡与卡之间留空隙，这是"这是两个不同的主项目"的唯一线索；
                //   · 展开 / 收起用 `AnimatedSize` 做**高度过渡** ——
                //     原来是直接重建列表，行数一变就"跳"一下，看着像动画坏了。
                for (final group in _groupByRoot(rows))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    child: Card(
                      margin: EdgeInsets.zero,
                      elevation: 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          KeyedSubtree(
                            key: ValueKey<String>(group.root.project.id),
                            child: _buildTile(group.root),
                          ),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                for (final child in group.children)
                                  KeyedSubtree(
                                    key: ValueKey<String>(child.project.id),
                                    child: _buildTile(child),
                                  ),
                                if (_addingChildOf == group.root.project.id)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      left: 40,
                                      bottom: 6,
                                    ),
                                    child: InlineComposer(
                                      label: '新建子项目',
                                      hint: '子项目名',
                                      leading: Icons.subdirectory_arrow_right,
                                      dense: true,
                                      onCreate: (title) => _create(
                                        parentId: group.root.project.id,
                                        title: title,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTile(_ProjectRow row) {
    final project = row.project;
    if (_renamingId == project.id) {
      return Padding(
        padding: EdgeInsets.only(left: 12.0 + row.depth * 16, right: 12),
        child: InlineTextField(
          value: project.title,
          autofocus: true,
          hint: '项目名',
          textStyle: Theme.of(context).textTheme.bodyLarge,
          onSubmitted: (title) =>
              _app.run(() => _app.ws.updateProject(project.id, title: title)),
          onEditClosed: () {
            if (mounted) setState(() => _renamingId = null);
          },
        ),
      );
    }
    return _ProjectTile(
      app: _app,
      row: row,
      onStartRename: () => setState(() => _renamingId = project.id),
      onStartAddChild: () => setState(() => _addingChildOf = project.id),
    );
  }
}

/// 一条扁平化后的项目行（已按折叠状态决定要不要展开后代）。
class _ProjectRow {
  const _ProjectRow({
    required this.project,
    required this.depth,
    required this.childCount,
    required this.expanded,
  });

  final Project project;
  final int depth;
  final int childCount;
  final bool expanded;
}

/// 一个主项目 + 它当前可见的下级（展开时才有）。
///
/// 之所以要分组：渲染成"每张卡一个主项目"需要知道哪些行属于同一个主项目，
/// 而 `_flatten` 返回的是一维列表。
class _ProjectGroup {
  const _ProjectGroup({required this.root, required this.children});

  final _ProjectRow root;
  final List<_ProjectRow> children;
}

/// 把一维列表按"根"分组：depth == 0 开新组，后面的 depth > 0 归到它下面。
List<_ProjectGroup> _groupByRoot(List<_ProjectRow> rows) {
  final groups = <_ProjectGroup>[];
  var currentRoot = <_ProjectRow>[];
  var currentChildren = <_ProjectRow>[];

  void flush() {
    if (currentRoot.isEmpty) return;
    groups.add(
      _ProjectGroup(root: currentRoot.first, children: currentChildren),
    );
    currentRoot = <_ProjectRow>[];
    currentChildren = <_ProjectRow>[];
  }

  for (final row in rows) {
    if (row.depth == 0) {
      flush();
      currentRoot = <_ProjectRow>[row];
    } else {
      currentChildren.add(row);
    }
  }
  flush();
  return groups;
}

List<_ProjectRow> _flatten(AppController app) {
  final tree = app.ws.projectTree;
  final rows = <_ProjectRow>[];

  void walk(String? parentId, int depth) {
    for (final project in tree.childrenOf(parentId).whereType<Project>()) {
      if (project.archived) continue;
      final children = tree
          .childrenOf(project.id)
          .whereType<Project>()
          .where((p) => !p.archived)
          .toList(growable: false);
      final expanded = app.isExpanded(project.id);
      rows.add(
        _ProjectRow(
          project: project,
          depth: depth,
          childCount: children.length,
          expanded: expanded,
        ),
      );
      if (children.isNotEmpty && expanded) walk(project.id, depth + 1);
    }
  }

  walk(null, 0);
  return rows;
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.app,
    required this.row,
    required this.onStartRename,
    required this.onStartAddChild,
  });

  final AppController app;
  final _ProjectRow row;
  final VoidCallback onStartRename;
  final VoidCallback onStartAddChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = row.project;
    final due = describeDate(project.date);
    final overdue =
        isOverdue(project.date) && project.status != NodeStatus.done;
    // 子项目（depth > 0）用**更紧凑**的一档样式：
    // 原来只缩进了 16dp、字号仍是 `bodyLarge`，看起来和顶层项目一样重，
    // 既没体现层级、又白占一块纵向空间（实机反馈）。
    final isChild = row.depth > 0;

    return ListTile(
      dense: isChild,
      visualDensity: isChild ? VisualDensity.compact : VisualDensity.standard,
      // 主项目靠左（4dp 起），子项目明显右移 —— 靠**缩进差**表达主从关系，
      // 而不是靠字号或分割线（实机反馈：原来的缩进差看不出来）
      contentPadding: EdgeInsets.only(left: isChild ? 36 : 4, right: 4),
      minLeadingWidth: isChild ? 18 : null,
      // 左侧图标**槽位宽度固定**（实机反馈"第一条的左侧没有对齐"）：
      // 展开箭头是 `IconButton`、状态图标是 `Icon`，两者宽度本来就不同，
      // 各画各的会把标题挤到不同的竖线上 —— 有子项目的、没子项目的、
      // 有没有标识色的，标题必须都在同一条线上。
      leading: SizedBox(
        width: isChild ? 18 : 40,
        child: Center(
          child: row.childCount == 0
              ? (isChild
                    // 子项目用标识色小圆点：比状态图标轻，色点本身也表达归属
                    ? ProjectMarker(color: project.color, size: 12)
                    : Icon(
                        nodeStatusIcon(project.status),
                        size: 20,
                        color: nodeStatusColor(
                          project.status,
                          theme.colorScheme,
                        ),
                      ))
              : IconButton(
                  tooltip: row.expanded ? '收起' : '展开',
                  iconSize: isChild ? 18 : 22,
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(
                    width: isChild ? 18 : 32,
                    height: isChild ? 18 : 32,
                  ),
                  // 箭头**转过去**而不是换一个图标（实机反馈：加个动画）：
                  // `chevron_right` 顺时针转 90° 正好是"朝下 = 已展开"
                  icon: AnimatedRotation(
                    turns: row.expanded ? 0.25 : 0,
                    duration: _foldDuration,
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.chevron_right),
                  ),
                  onPressed: () =>
                      app.setExpanded(project.id, expanded: !row.expanded),
                ),
        ),
      ),
      title: Row(
        children: <Widget>[
          // 标识色（灵感整理第 10 条）：一小段色条，扫一眼就能把项目区分开。
          // **槽位固定占位**：没设色的行也留出同样宽度，标题才不会一行一个位置
          // （实机反馈"第一条的左侧没有对齐"）。子项目已有色点，不再画色条。
          if (!isChild)
            SizedBox(
              width: 10,
              child: Align(
                alignment: Alignment.centerLeft,
                child: colorOfHex(project.color) == null
                    ? null
                    : Container(
                        width: 4,
                        height: 16,
                        decoration: BoxDecoration(
                          color: colorOfHex(project.color),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
              ),
            ),
          Expanded(
            child: Text(
              project.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 子项目降一档字号，层级靠字号与缩进一起表达
              style: isChild
                  ? theme.textTheme.bodyMedium?.copyWith(
                      decoration: project.status == NodeStatus.done
                          ? TextDecoration.lineThrough
                          : null,
                      color: project.status == NodeStatus.done
                          ? theme.colorScheme.outline
                          : null,
                    )
                  : (project.status == NodeStatus.done
                        ? theme.textTheme.bodyLarge?.copyWith(
                            decoration: TextDecoration.lineThrough,
                            color: theme.colorScheme.outline,
                          )
                        : null),
            ),
          ),
        ],
      ),
      // 子项目的副标题只留必要信息（日期 / 子项目数），目的那一长串不再重复显示
      subtitle: isChild
          ? _childSubtitle(theme, project, row, due, overdue)
          : _Subtitle(row: row, due: due, overdue: overdue),
      trailing: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (value) async {
          await _handleMenu(context, value);
        },
        // 「新建子项目」与「打开详情」都已去掉（按实机反馈）：
        //   · 打开详情：点这一行本身就是打开详情，菜单里再放一个是重复入口；
        //   · 新建子项目：进详情页用那个加号建（那里还能顺手填目的/日期）。
        itemBuilder: (_) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
          PopupMenuItem<String>(value: 'move', child: Text('移动到…')),
          PopupMenuItem<String>(value: 'archive', child: Text('归档')),
          PopupMenuItem<String>(value: 'delete', child: Text('删除')),
        ],
      ),
      onTap: () => _open(context),
    );
  }

  Future<void> _handleMenu(BuildContext context, String value) async {
    final project = row.project;
    switch (value) {
      case 'rename':
        onStartRename();
        break;
      case 'move':
        await moveProjectAction(context, app, project.id);
        break;
      case 'archive':
        await archiveProjectAction(context, app, project.id, archived: true);
        break;
      case 'delete':
        await deleteProjectAction(context, app, project.id);
        break;
    }
  }

  Future<void> _open(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProjectDetailPage(app: app, projectId: row.project.id),
      ),
    );
  }
}

/// 子项目的副标题：**只留必要信息**，没有就不显示。
///
/// 顶层项目的副标题会带「目的」那一长串；子项目在树里已经缩进一层了，
/// 再抄一遍目的只会把行撑高、层级更糊（实机反馈"间距过大"）。
Widget? _childSubtitle(
  ThemeData theme,
  Project project,
  _ProjectRow row,
  String due,
  bool overdue,
) {
  final style = theme.textTheme.labelSmall;
  final parts = <Widget>[];
  if (due.isNotEmpty) {
    parts.add(
      Text(
        due,
        style: style?.copyWith(color: overdue ? theme.colorScheme.error : null),
      ),
    );
  }
  if (row.childCount > 0) {
    if (parts.isNotEmpty) parts.add(const SizedBox(width: 8));
    parts.add(Text('${row.childCount} 个子项目', style: style));
  }
  if (parts.isEmpty) return null;
  return Row(children: parts);
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({
    required this.row,
    required this.due,
    required this.overdue,
  });

  final _ProjectRow row;
  final String due;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = row.project;
    final style = theme.textTheme.labelSmall;
    return Row(
      children: <Widget>[
        if (due.isNotEmpty) ...<Widget>[
          Icon(
            Icons.event,
            size: 13,
            color: overdue
                ? theme.colorScheme.error
                : theme.colorScheme.outline,
          ),
          const SizedBox(width: 3),
          Text(
            due,
            style: style?.copyWith(
              color: overdue ? theme.colorScheme.error : null,
            ),
          ),
          const SizedBox(width: 10),
        ],
        if (row.childCount > 0) ...<Widget>[
          const Icon(Icons.account_tree_outlined, size: 13),
          const SizedBox(width: 3),
          Text('${row.childCount} 个子项目', style: style),
          const SizedBox(width: 10),
        ],
        if (project.purpose.isNotEmpty)
          Expanded(
            child: Text(
              project.purpose,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
      ],
    );
  }
}
