/// 主线流图的**渲染排布**。
///
/// 和 `TaskFlow`（只管图）分开：这里只管"按什么顺序、缩进几层、带什么徽标"，
/// 是一段纯函数，所以分叉 / 合流这种最容易排错的逻辑可以直接单测。
///
/// 排布规则：
///   · 主线节点按走向顺序平铺（depth 0）；
///   · 遇到**分叉**：先渲染分叉点（带「分出 n 条支路」徽标），
///     再把每条支路渲染成**缩进的一组**（depth 1，带「支路 n」小标题），
///     最后渲染**合流点**（回到 depth 0，带「n 条支路在此汇合」徽标）；
///   · 每条支路走到合流点 / 汇入他处为止，支路内部仍照走向走；
///   · **每个节点只渲染一次**；万一有节点没被走到（畸形数据），
///     补在最后并标注「未接入主线」—— 宁可难看，不能丢。
library;

import '../../core/models/task.dart';
import '../../core/tree/task_flow.dart';

/// 一行渲染项：要么是一个任务节点，要么是支路小标题。
class FlowRow {
  const FlowRow.node(this.task, {required this.depth, this.branchIndex, this.badge})
      : branchTitle = null,
        branchCount = 0;

  const FlowRow.branchHeader({
    required this.branchIndex,
    required this.branchCount,
    required this.depth,
  })  : task = null,
        badge = null,
        branchTitle = '支路';

  final Task? task;

  /// 支路小标题那一种行
  final String? branchTitle;

  /// 缩进层级：0 = 主线，1 = 支路内部
  final int depth;

  /// 第几条支路（从 0 起）；主线节点为 `null`
  final int? branchIndex;

  /// 支路总数（小标题行用）
  final int branchCount;

  /// 徽标：分叉 / 合流 / 未接入
  final String? badge;

  bool get isBranchHeader => branchTitle != null;
}

/// 把流图摊成可逐行渲染的列表。
List<FlowRow> layoutTaskFlow(TaskFlow flow) {
  if (flow.isEmpty) return const <FlowRow>[];

  final rows = <FlowRow>[];
  final rendered = <String>{};

  for (final root in flow.roots) {
    _walkMain(flow, root, 0, rows, rendered);
  }

  // 兜底：任何没被走到的节点都要出现。
  // 实际上 `TaskFlow` 已保证"每个节点都能从某个入口走到"，所以这里**不会触发** ——
  // 留着是防御性的：将来若给 TaskFlow 加了过滤、可能造出孤立节点，至少不会丢任务。
  for (final task in flow.all) {
    if (!rendered.contains(task.id)) {
      _addNode(rows, rendered, task, 0, badge: '未接入主线');
    }
  }

  return rows;
}

void _addNode(
  List<FlowRow> rows,
  Set<String> rendered,
  Task task,
  int depth, {
  int? branchIndex,
  String? badge,
}) {
  if (!rendered.add(task.id)) return;
  rows.add(FlowRow.node(task, depth: depth, branchIndex: branchIndex, badge: badge));
}

/// 主线：顺序往下，遇到分叉就展开支路。
void _walkMain(
  TaskFlow flow,
  Task task,
  int depth,
  List<FlowRow> rows,
  Set<String> rendered, {
  int? branchIndex,
}) {
  if (rendered.contains(task.id)) return;

  final successors = flow.successorsOf(task.id);
  if (successors.length >= 2) {
    _addNode(rows, rendered, task, depth, branchIndex: branchIndex, badge: '分出 ${successors.length} 条支路');
    final join = _findJoin(flow, successors);
    for (var i = 0; i < successors.length; i += 1) {
      final branch = successors[i];
      if (rendered.contains(branch.id)) continue;
      rows.add(
        FlowRow.branchHeader(
          branchIndex: i,
          branchCount: successors.length,
          depth: depth + 1,
        ),
      );
      _walkBranch(flow, branch, join, i, rows, rendered);
    }
    if (join != null) _walkMain(flow, join, depth, rows, rendered);
    return;
  }

  _addNode(
    rows,
    rendered,
    task,
    depth,
    branchIndex: branchIndex,
    badge: flow.isJoin(task.id) ? '${flow.predecessorCountOf(task.id)} 条支路在此汇合' : null,
  );
  for (final next in successors) {
    _walkMain(flow, next, depth, rows, rendered, branchIndex: branchIndex);
  }
}

/// 支路内部：沿着单后继一路走下去，碰到合流点或汇入别人就停。
void _walkBranch(
  TaskFlow flow,
  Task start,
  Task? join,
  int branchIndex,
  List<FlowRow> rows,
  Set<String> rendered,
) {
  var current = start;
  while (true) {
    if (rendered.contains(current.id)) return;
    if (join != null && current.id == join.id) return;

    final successors = flow.successorsOf(current.id);
    _addNode(rows, rendered, current, 1, branchIndex: branchIndex);

    if (successors.length != 1) {
      // 支路内部又分叉（嵌套），或者这条支路走到头了
      for (final next in successors) {
        if (join != null && next.id == join.id) continue;
        _walkMain(flow, next, 1, rows, rendered, branchIndex: branchIndex);
      }
      return;
    }

    final next = successors.single;
    if (join != null && next.id == join.id) return;
    // 汇入了支路之外的地方（例如另一条支路的成果），到此为止
    if (flow.predecessorCountOf(next.id) > 1) return;
    current = next;
  }
}

/// 找合流点：**被每条支路都可达**、且前驱 ≥ 2 的最近一个节点。
///
/// 找不到就返回 `null`（例如两条支路各走各的、永不合流），
/// 这时每条支路一直渲染到自己的尽头。
Task? _findJoin(TaskFlow flow, List<Task> branches) {
  final reachable = <Set<String>>[];
  for (final branch in branches) {
    final seen = <String>{};
    final stack = <String>[branch.id];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (!seen.add(id)) continue;
      for (final next in flow.successorsOf(id)) {
        stack.add(next.id);
      }
    }
    reachable.add(seen);
  }

  final candidates = flow.all
      .where((task) =>
          flow.predecessorCountOf(task.id) > 1 &&
          reachable.every((set) => set.contains(task.id)))
      .toList(growable: false);
  if (candidates.isEmpty) return null;

  return candidates.reduce((a, b) => flow.layerOf(a.id) <= flow.layerOf(b.id) ? a : b);
}
