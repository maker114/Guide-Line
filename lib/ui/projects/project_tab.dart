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

/// 行首"标识槽"的宽度：**展开 / 收起的点击热区就取这一整槽**（40dp）。
///
/// 竖条本身只有 4dp 宽，单点那 4dp 点不中；槽位做成 40dp 宽 × 整行高，
/// 热区就跟着有 40dp —— 槽位是透明的，加宽它**不改变外观**。
const double _railSlotWidth = 40;

/// 竖条 / 竖轨的宽度（同一档）。
const double _railWidth = 4;

/// 标识槽与行内容之间的间距（槽右缘 → 标题左缘）。
const double _railSlotGap = 8;

/// 子目标标识色圆点的直径（《界面规范》：色点用正圆）。
const double _markerSize = 12;

/// 圆点圆心相对竖轨右缘的偏移（用户口径：圆点画在**竖轨右侧约 14dp 处**）。
const double _markerOffset = 14;

/// 行内容的左内边距 = 标识槽 + 间距。
///
/// 改版前（实测屏幕坐标）：根层行标题左缘 72、子行 78；
/// 改版后两档都是 **60**（= 卡片左缘 12 + 这里的 48）——
/// 分类行与子行的文字都比原来靠左，且标题与竖轨之间留着 44dp（要求 ≥8dp）。
const double _contentLeft = _railSlotWidth + _railSlotGap;

/// 行首那条竖线的 Key：用例靠它确认"没设色的项目用的是灰条，而不是空位"，
/// 也靠它量"展开后每行的轨段首尾相接"。
///
/// 它挂在**这一行自己的那一段竖线**上（2026-09-26 项目页改版）：
///   · 分类展开时 = 整行高的一段轨（`ProjectColorBar.stretch`）；
///   · 分类收起时、根层目标 = 一条 18dp 的短色条（`ProjectColorBar.leading`）。
@visibleForTesting
Key projectColorBarKey(String projectId) => Key('ProjectTile.colorBar.$projectId');

/// 一整行（外层 `Stack`）的 Key：标识槽与 `ListTile` 是**兄弟**而不是父子，
/// 用例要按行找"槽里的圆点 / 竖条"就得先按住这一行。
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
/// 手机上没有树控件的余地，所以用「扁平化 + 行首竖轨 + 展开色条」渲染：
/// 折叠状态存在 `UiPrefs` 里，下次进来还是原样。
///
/// 行首的标识与展开交互（2026-09-26 用户逐条敲定）：
///   · **分类行**：最左是一根竖色条，**点它就是展开 / 收起** —— 展开箭头已去掉；
///     展开后这根条向下延伸成一条竖轨，把"分类 + 它当前可见的全部子行"框起来。
///     实现上是**每一行各画自己那一段**（同色、首尾相接），不是一个量高度的
///     跨行 `Stack`：前者天然连续、也不怕行高变化；
///   · **子行**：竖轨右侧约 14dp 处仍是**子项自己的颜色圆点**（没设色 = 灰空心圆）；
///   · **根层目标**（没下级）：最左也是一条竖条（自己的颜色，没设色用中性灰），
///     但**不可点、不延伸**。
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
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '分类只用来归类；真正要交出的结果叫「目标」，灵感合并进目标的「如何解决」',
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
                                      left: _contentLeft,
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
    required this.railColor,
  });

  final Project project;
  final int depth;
  final int childCount;
  final bool expanded;

  /// 这一行的竖线用什么颜色（2026-09-26 改版）：
  ///   · **分类行 = 自己的颜色** —— 它是这一组竖轨的轨头；
  ///   · **根层目标 = 自己的颜色**（占位短条，不延伸）；
  ///   · **子目标 = 上级分类的颜色** —— 它只是那条轨上的一段，
  ///     颜色跟随轨头，否则一条轨会一行一个色。
  final String? railColor;

  /// 角色判据（《定义与边界》§2.1）：**有下级 = 分类，没有下级 = 目标**。
  bool get isCategory => childCount > 0;

  /// 这一行的竖线是"一整段轨"（占满整行高、与相邻行首尾相接），
  /// 还是一条 18dp 的短色条：
  ///   · 分类展开时 = 轨段（它下面还接着子行的那几段）；
  ///   · 分类收起时 = 短色条（它自己就是展开控件，不延伸）；
  ///   · 根层目标 = 短色条（不可点、不延伸）；
  ///   · 子目标 = 轨段（可见就说明上级分类是展开的）。
  bool get railSpansRow => isCategory ? expanded : depth > 0;
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

  /// [inheritedRail] = 当前这条轨的颜色（最近的展开分类自己的颜色）。
  void walk(String? parentId, int depth, String? inheritedRail) {
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
          // 分类与根层目标用自己的颜色（短条也好、轨头也好，都是"我是谁"）；
          // 子目标接上级那条轨的颜色。
          railColor: (isCategory || depth == 0)
              ? project.color
              : inheritedRail,
        ),
      );
      if (isCategory && expanded) walk(project.id, depth + 1, project.color);
    }
  }

  walk(null, 0, null);
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

    return Stack(
      key: projectRowKey(project.id),
      children: <Widget>[
        ListTile(
          dense: isChild,
          visualDensity:
              isChild ? VisualDensity.compact : VisualDensity.standard,
          // 行首那条槽（竖轨 / 短色条 + 圆点）与 `ListTile` 是**兄弟**：
          // `ListTile` 的 leading 槽没法画"占满整行高的竖轨"（它的 leading 只能
          // 按标题那一块的高度居中），所以槽位单独放，行内容把左内边距让出来。
          //
          // 内容左内边距 = 标识槽 40dp + 间距 8dp（`_contentLeft`）：
          // 根层行由 60dp 收到 48dp、子行由 66dp 收到 48dp —— 两档都更靠左，
          // 且标题与竖轨之间留着 44dp（要求 ≥8dp）。
          contentPadding: const EdgeInsets.only(left: _contentLeft, right: 4),
          title: Text(
            project.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 子项目降一档字号，层级靠字号与缩进一起表达
            style: isChild ? theme.textTheme.bodyMedium : null,
          ),
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
            // 「新建下级」与「打开详情」都已去掉（按实机反馈）：
            //   · 打开详情：点这一行本身就是打开详情，菜单里再放一个是重复入口；
            //   · 新建下级：进详情页用那个「新建目标」建（那里还能顺手填"有什么问题 / 思路"与日期）。
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
              PopupMenuItem<String>(value: 'move', child: Text('移动到…')),
              PopupMenuItem<String>(value: 'archive', child: Text('归档')),
              PopupMenuItem<String>(value: 'delete', child: Text('删除')),
            ],
          ),
          onTap: () => _open(context),
        ),
        // 最左那一整条槽：竖线 + （子目标的）色点。
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _railSlotWidth,
          child: _railSlot(),
        ),
      ],
    );
  }

  /// 行首的标识槽：**一条竖线**（分类展开后是整行高的一段轨）+ 子目标的色点。
  ///
  /// 这个槽同时也是**展开 / 收起的点击热区**（分类行整槽 40dp × 整行高 ——
  /// 条本身只有 4dp，单点它点不中）。它是透明的，加宽不改变外观。
  Widget _railSlot() {
    final project = row.project;
    // 竖线本身：展开的分类、子目标 = 占满整行高的一段轨；
    // 收起的分类、根层目标 = 一条 18dp 的短色条。
    final Widget rail = row.railSpansRow
        ? ProjectColorBar.stretch(
            key: projectColorBarKey(project.id),
            color: row.railColor,
            width: _railWidth,
          )
        : Center(
            child: ProjectColorBar.leading(
              key: projectColorBarKey(project.id),
              color: row.railColor,
            ),
          );

    final slot = Stack(
      children: <Widget>[
        Positioned(left: 0, top: 0, bottom: 0, width: _railWidth, child: rail),
        // 子目标自己的标识色圆点（**子项自己的颜色**，没设色 = 灰空心圆），
        // 画在竖轨右侧约 14dp 处 —— 圆点在这条槽里，不在标题前。
        if (row.depth > 0 && !row.isCategory)
          Positioned(
            left: _railWidth + _markerOffset - _markerSize / 2,
            top: 0,
            bottom: 0,
            width: _markerSize,
            child: Center(
              child: ProjectMarker(color: project.color, size: _markerSize),
            ),
          ),
      ],
    );

    // 分类行：**整条槽就是展开控件**（用户口径：点色条展开 / 收起，不给别的提示）。
    // 目标行：槽位不接手势 —— 点它照旧落到整行上（打开详情），别成一个死区。
    if (!row.isCategory) return IgnorePointer(child: slot);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => app.setExpanded(project.id, expanded: !row.expanded),
      child: slot,
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
