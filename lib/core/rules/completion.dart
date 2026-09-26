import '../models/entity.dart';
import '../models/enums.dart';
import '../tree/tree_index.dart';

/// 完成规则（设计文档 4.6 / ADR-054 / ADR-055）。
///
/// 全系统唯一规则：
///   **节点可被标记「已完成」⟺ 它所有「参与判定」的直接子节点都处于 done 或 ignored。**
///
/// 判定域：`deleted`（墓碑）与 `archived`（已归档）节点**既不阻塞、也不满足**。
/// 方向不对称：**自动「退回」允许，自动「完成」禁止**。

bool isTerminal(NodeStatus status) =>
    status == NodeStatus.done || status == NodeStatus.ignored;

/// 参与完成判定的直接子节点。
List<EntityNode> judgedChildren(TreeIndex index, String nodeId) {
  return index
      .childrenOf(nodeId)
      .where((child) => !child.deleted && !child.archived)
      .toList(growable: false);
}

/// 完成检查结果（UI 直接消费，不需要自己判断规则）。
class CompletionCheck {
  const CompletionCheck({
    required this.canComplete,
    required this.judgedChildCount,
    required this.unfinishedCount,
  });

  final bool canComplete;
  final int judgedChildCount;
  final int unfinishedCount;

  /// 条件未满足时给用户的解释（"还有 2 个子节点未处理"）。
  ///
  /// 现在只有**事件与任务**会用到它：项目没有完成态（《定义与边界》§2.1/Q1），
  /// 所以"父项目为什么还不能完成"这句话整体消失了。
  String? get reason => canComplete ? null : '还有 $unfinishedCount 个子节点未处理';
}

CompletionCheck checkCompletion(TreeIndex index, String nodeId) {
  final children = judgedChildren(index, nodeId);
  final unfinished = children.where((c) => !isTerminal(c.status)).length;
  return CompletionCheck(
    canComplete: unfinished == 0,
    judgedChildCount: children.length,
    unfinishedCount: unfinished,
  );
}

/// 反向传播：当 [nodeId] 变成非终态（或新挂了非终态子节点）时，
/// 返回**必须退回 pending 的祖先**（自下向上，含所有已完成的祖先）。
///
/// 调用方在改完数据后调用它，把返回值置为 pending 并清空 `completedAt`。
List<String> ancestorsToRevert(TreeIndex index, String nodeId) {
  final out = <String>[];
  for (final ancestor in index.ancestorsOf(nodeId)) {
    if (ancestor.status == NodeStatus.done) out.add(ancestor.id);
  }
  return out;
}

/// 新增子节点后，父节点是否已处于 `done` 而需要退回。
List<String> parentsToRevertAfterInsert(TreeIndex index, String newChildId) {
  final child = index.byId[newChildId];
  if (child == null) return const <String>[];
  if (child.deleted || child.archived) return const <String>[];
  if (isTerminal(child.status)) return const <String>[];
  return ancestorsToRevert(index, newChildId);
}
