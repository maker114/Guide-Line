import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/project.dart';
import '../../features/workspace.dart';
import '../common/color_picker.dart';
import '../common/dialogs.dart';
import '../common/format.dart';
import '../common/inline_editor.dart';
import 'project_actions.dart';
import 'project_detail_page.dart';

/// 根行（**分类与根目标**）行内容的左内边距。
///
/// 少了"展开箭头"那 40dp 的图标槽之后，标识色条回到标题前紧挨着，
/// 根行可以直接从 16dp 起 —— 比上一版（槽 40 + 间距 8 = 48）靠左一大截。
const double _rootContentLeft = 16;

/// 子行行内容的左内边距：比根行多一档，保住"子项缩进一层"的既有观感。
const double _childContentLeft = 28;

/// 标题前那根标识色条与标题之间的间距（根行）。
const double _barTitleGap = 6;

/// 子行标题前那个**色点槽**的宽度。
///
/// 槽内**左对齐**放一个 12dp 的圆点，剩下的 6dp 正好是圆点与标题的间距 ——
/// 与根行"色条右缘 → 标题"的 6dp 同值，两种记号排下来才匀称。
const double _markerSlotWidth = 18;

/// 子目标标识色圆点的直径（《界面规范》：色点用正圆）。
const double _markerSize = 12;

/// 标题前那根标识色条的 Key（**只有根行**：分类 / 根目标）。
///
/// 用例靠它确认"没设色的项目用的是灰条，而不是空位"，也靠它量
/// "色条在标题左侧、不在行最左那一列"。子行标题前放的是色点
/// （`ProjectMarker`），不挂这个 Key。
@visibleForTesting
Key projectColorBarKey(String projectId) => Key('ProjectTile.colorBar.$projectId');

/// 一整行的 Key（挂在 `ListTile` 上）：用例靠它量"标题相对行左缘的内边距"。
@visibleForTesting
Key projectRowKey(String projectId) => Key('ProjectTile.row.$projectId');

/// 标题栏那个数字（「项目   3」）：**最外层有几条**。
///
/// 口径（2026-09-26 用户确认）：
///   · **只数最外层** —— 分类下面的目标、甚至再套一层子分类，都不计入；
///     例如 A / B / C 都属于「分类1」，那么只算「分类1」这一条；
///   · **已归档的不计入**（它本来就不在列表里）；
///   · **与收起 / 展开无关** —— 这里原来取的是"列表里画出来的行数"，
///     于是一收起分类，标题上的数字就跟着变小（实机反馈的 bug）。
int rootProjectCount(AppController app) => app.ws.projectTree
    .childrenOf(null)
    .whereType<Project>()
    .where((project) => !project.archived && !project.deleted)
    .length;

/// 项目 Tab：**项目树（≤ 3 层）**。
///
/// 手机上没有树控件的余地，所以用「扁平化 + 行首标识 + 行尾菜单展开」渲染：
/// 折叠状态存在 `UiPrefs` 里，下次进来还是原样。
///
/// 行首的标识与展开交互（2026-09-26 用户逐条敲定，第二版）：
///   · **不点色条展开**、**也没有展开箭头** —— 展开 / 收起收进行尾的 ⋮ 菜单，
///     且**只有"有下级"的分类行**才有「展开下级」/「收起下级」这一项；
///   · **分类行与根目标行**：标题左侧紧挨一根竖色条（`ProjectColorBar` 默认档，
///     没设色用中性灰补齐），两行的**标题起始竖线一致**；
///   · **子行**：标题前是自己那个 12dp 的色点（`ProjectMarker`，没设色 = 灰空心圆），
///     整行再缩进一档；子行不画色条（一个记号只出现一次）。
///   · 行内容左内边距：根行 16dp、子行 28dp（见 `_rootContentLeft` /
///     `_childContentLeft`）。
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
      if (mounted) showToast(context, error, error: true);
      return;
    }
    // 加完子项目就把那一行的输入框收起来，避免列表里挂着一排展开的输入
    if (parentId != null) setState(() => _addingChildOf = null);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _flatten(_app);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 数量原来单独占一行（「共 4 个项目」），被标题栏的「项目   4」接管了 ——
        // 这里只在**一个项目都没有**时留一句引导，有项目时不占行。
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(
              '还没有项目',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: <Widget>[
              InlineComposer(
                label: '新建分类',
                hint: '分类名',
                leading: Icons.create_new_folder_outlined,
                onCreate: (title) => _create(title: title),
              ),
              if (rows.isNotEmpty)
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
                                      left: _childContentLeft,
                                      bottom: 6,
                                    ),
                                    child: InlineComposer(
                                      label: '新建目标',
                                      hint: '目标名',
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

  /// 角色判据（《定义与边界》§2.1）：**有下级 = 分类，没有下级 = 目标**。
  ///
  /// 这一条同时决定两件事：标题前放**色条**（根行，分类与根目标一样）
  /// 还是放**色点**（子行）；以及 ⋮ 菜单里**有没有**「展开下级 / 收起下级」。
  bool get isCategory => childCount > 0;
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
      // 角色与下级列表同源：都用 `Workspace.childProjectsOf`（未归档、未删除的直属下级）
      final children = app.ws.childProjectsOf(project.id);
      final expanded = app.isExpanded(project.id);
      final isCategory = children.isNotEmpty;
      rows.add(
        _ProjectRow(
          project: project,
          depth: depth,
          childCount: children.length,
          expanded: expanded,
        ),
      );
      if (isCategory && expanded) walk(project.id, depth + 1);
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
    // 项目没有完成态（Q1）：日期只按日期本身判逾期，不再看 `status`。
    final overdue = isOverdue(project.date);
    // 子项目（depth > 0）用**更紧凑**的一档样式：
    // 原来只缩进了 16dp、字号仍是 `bodyLarge`，看起来和顶层项目一样重，
    // 既没体现层级、又白占一块纵向空间（实机反馈）。
    final isChild = row.depth > 0;

    return ListTile(
      key: projectRowKey(project.id),
      dense: isChild,
      visualDensity: isChild ? VisualDensity.compact : VisualDensity.standard,
      // 行内容左内边距：根行 16dp、子行 28dp。
      //
      // 上一版把标识放进 `ListTile` 外面的"最左 40dp 标识槽"（`Stack` +
      // `Positioned`），行内容因此要把那 40dp 让出来（左内边距 48dp）；
      // 现在色条回到标题前、色点也只在标题前那 18dp 的槽里，整行跟着左移。
      contentPadding: EdgeInsets.only(
        left: isChild ? _childContentLeft : _rootContentLeft,
        right: 4,
      ),
      title: _titleRow(context),
      // 分类行只给**汇总**（Q2）：目的 / 实现计划 / 实现清单 / 日期 / 状态一律不显示 ——
      // 分类只回答"归哪一类"。
      //
      // **一眼看出没有副标题时给 `null`**（实机反馈"第四条项目没有目标，标题
      // 略微下移保证居中"）：留一个空副标题占位会让这一行和两行的行一样高、
      // 内容却都挤在上半截，看着头重脚轻。给它真的没有副标题，ListTile 就按
      // 单行排版，标题自然竖直居中、行也短一截。
      subtitle: row.isCategory
          ? _categorySubtitle(theme, app.ws.summarizeCategory(project.id))
          : (isChild
                ? _childSubtitle(theme, project, row, due, overdue)
                : _rootSubtitle(theme, project, row, due, overdue)),
      trailing: PopupMenuButton<String>(
        tooltip: '更多',
        onSelected: (value) async {
          await _handleMenu(context, value);
        },
        // 展开 / 收起收进这个菜单（2026-09-26 第二版：不再点色条展开），
        // 且**只有"有下级"的分类行**才有这一项 —— 没有下级的行给它是空按钮。
        // 文案与事件详情页的折叠开关同一套（「展开下级」/「收起下级」）。
        //
        // 「新建下级」与「打开详情」都已去掉（按实机反馈）：
        //   · 打开详情：点这一行本身就是打开详情，菜单里再放一个是重复入口；
        //   · 新建下级：进详情页用那个「新建目标」建（那里还能顺手填"有什么问题 / 思路"与日期）。
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          if (row.isCategory)
            PopupMenuItem<String>(
              value: row.expanded ? 'collapse' : 'expand',
              child: Text(row.expanded ? '收起下级' : '展开下级'),
            ),
          const PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
          const PopupMenuItem<String>(value: 'move', child: Text('移动到…')),
          const PopupMenuItem<String>(value: 'archive', child: Text('归档')),
          const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
        ],
      ),
      onTap: () => _open(context),
    );
  }

  /// 标题那一行：**标识 + 标题**。
  ///
  /// 标识曾经单独占最左那一整列（`Stack` + `Positioned` 的"标识槽"），
  /// 现在回到标题左侧（2026-09-26 第二版：用户反馈"色条太靠左"）。
  /// 两种形状按层级分工，**一行里只出现一个记号**：
  ///   · **根行**（分类 / 根目标）→ 一根竖色条（`ProjectColorBar` 默认档）；
  ///   · **子行** → 自己那个 12dp 的色点（`ProjectMarker`），整行再缩进一档。
  Widget _titleRow(BuildContext context) {
    final theme = Theme.of(context);
    final project = row.project;
    final title = Text(
      project.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // 子项目降一档字号，层级靠字号与缩进一起表达
      style: row.depth > 0 ? theme.textTheme.bodyMedium : null,
    );

    if (row.depth > 0) {
      return Row(
        children: <Widget>[
          SizedBox(
            width: _markerSlotWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: ProjectMarker(color: project.color, size: _markerSize),
            ),
          ),
          Expanded(child: title),
        ],
      );
    }

    return Row(
      children: <Widget>[
        ProjectColorBar(
          key: projectColorBarKey(project.id),
          color: project.color,
        ),
        const SizedBox(width: _barTitleGap),
        Expanded(child: title),
      ],
    );
  }

  Future<void> _handleMenu(BuildContext context, String value) async {
    final project = row.project;
    switch (value) {
      case 'expand':
        app.setExpanded(project.id, expanded: true);
        break;
      case 'collapse':
        app.setExpanded(project.id, expanded: false);
        break;
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

/// 分类行的副标题：**只有汇总**（Q2）。
///
/// 口径与 `Workspace.summarizeCategory` 同源，只用契约里已有的字段：
///   · `含 N 个目标` —— 这棵子树下"没有下级"的项目有几个；
///   · `清单 d/t 已完成` —— 这些目标的「实现清单」条目里勾了多少（没有条目就不写）。
///
/// **不显示目的 / 实现计划 / 实现清单 / 日期 / 状态**：分类只回答"归哪一类"。
Widget _categorySubtitle(ThemeData theme, CategorySummary summary) {
  final style = theme.textTheme.labelSmall;
  return Row(
    children: <Widget>[
      Text('含 ${summary.targetCount} 个目标', style: style),
      if (summary.itemTotal > 0) ...<Widget>[
        const SizedBox(width: 8),
        Text(
          '清单 ${summary.itemDone}/${summary.itemTotal} 已完成',
          style: style,
        ),
      ],
    ],
  );
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

/// 根项目的副标题：日期 + 子项目数 + 目的（有哪个写哪个）。
///
/// **一个都没有时返回 `null`**，而不是塞一个空 `Row`：留着空占位会让这一行
/// 和两行的行一样高、内容却挤在上半截（实机反馈"第四条项目没有目标"）。
/// 返回 `null` 之后 ListTile 按单行排版，标题竖直居中、行也短一截。
Widget? _rootSubtitle(
  ThemeData theme,
  Project project,
  _ProjectRow row,
  String due,
  bool overdue,
) {
  final style = theme.textTheme.labelSmall;
  final parts = <Widget>[
    if (due.isNotEmpty) ...<Widget>[
      Icon(
        Icons.event,
        size: 13,
        color: overdue ? theme.colorScheme.error : theme.colorScheme.outline,
      ),
      const SizedBox(width: 3),
      Text(
        due,
        style: style?.copyWith(color: overdue ? theme.colorScheme.error : null),
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
  ];
  if (parts.isEmpty) return null;
  return Row(children: parts);
}
