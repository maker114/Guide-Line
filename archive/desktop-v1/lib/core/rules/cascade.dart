import '../models/inspiration.dart';
import '../models/task.dart';
import '../tree/tree_index.dart';

/// 级联规则（设计文档 4.5 / 4.7 / ADR-051 / ADR-056）。
///
/// 这些函数**只计算 id 集合**，不修改对象 —— 由数据层统一落库，
/// 这样「先算再写」可测试，也便于跨文档走一次事务提交。

/// 级联删除：自身 + 全部后代（已是墓碑的节点跳过，避免重复）。
Set<String> cascadeDeleteIds(TreeIndex index, String rootId) {
  final out = <String>{};
  for (final node in index.subtreeOf(rootId)) {
    if (!node.deleted) out.add(node.id);
  }
  return out;
}

/// 级联归档：**归档与取消归档都沿树级联**（ADR-051，用户裁定）。
///
/// 已知代价：子节点此前被单独归档时，会被父节点的取消归档一并解除。
Set<String> cascadeArchiveIds(TreeIndex index, String rootId, bool archived) {
  final out = <String>{};
  for (final node in index.subtreeOf(rootId)) {
    if (node.deleted) continue;
    if (node.archived != archived) out.add(node.id);
  }
  return out;
}

/// 项目删除的跨文档影响面。
class ProjectDeletionPlan {
  const ProjectDeletionPlan({
    required this.projectIds,
    required this.inspirationIdsToDelete,
    required this.inspirationIdsToUnassign,
  });

  /// 需要置墓碑的项目（自身 + 全部子项目）。
  final Set<String> projectIds;

  /// 需要置墓碑的灵感：`status = pending` 且分配到被删项目下。
  final Set<String> inspirationIdsToDelete;

  /// 需要**回退为未分配 pending** 的灵感：`status = merged`（ADR-056）。
  ///
  /// 合并是"吸收"，项目没了内容就没了；退回可避免用户数据丢失。
  final Set<String> inspirationIdsToUnassign;

  int get affectedInspirationCount =>
      inspirationIdsToDelete.length + inspirationIdsToUnassign.length;
}

ProjectDeletionPlan planProjectDeletion(
  TreeIndex projectIndex,
  Iterable<Inspiration> inspirations,
  String rootId,
) {
  final projectIds = cascadeDeleteIds(projectIndex, rootId);
  final toDelete = <String>{};
  final toUnassign = <String>{};

  for (final inspiration in inspirations) {
    if (inspiration.deleted) continue;
    final belongsToDeletedProject = (inspiration.projectId != null &&
            projectIds.contains(inspiration.projectId)) ||
        (inspiration.mergedInto != null && projectIds.contains(inspiration.mergedInto));
    if (!belongsToDeletedProject) continue;

    if (inspiration.isMerged) {
      toUnassign.add(inspiration.id);
    } else {
      toDelete.add(inspiration.id);
    }
  }

  return ProjectDeletionPlan(
    projectIds: projectIds,
    inspirationIdsToDelete: toDelete,
    inspirationIdsToUnassign: toUnassign,
  );
}

/// 事件删除：该事件 + **整条任务线**（按 `event_id` 收集，不依赖树形位置）。
Set<String> eventDeletionTaskIds(Iterable<Task> tasks, String eventId) {
  final out = <String>{};
  for (final task in tasks) {
    if (task.deleted) continue;
    if (task.eventId == eventId) out.add(task.id);
  }
  return out;
}

/// 把一个节点移动到新父节点下的合法性（设计文档 4.11）。
class MoveCheck {
  const MoveCheck({required this.allowed, required this.reason});

  final bool allowed;
  final String? reason;
}

MoveCheck checkMove({
  required TreeIndex index,
  required String nodeId,
  required String? newParentId,
  required int maxDepth,
  required bool crossEvent,
}) {
  if (nodeId == newParentId) {
    return const MoveCheck(allowed: false, reason: '不能移动到自身下面');
  }
  if (index.wouldCreateCycle(nodeId, newParentId)) {
    return const MoveCheck(allowed: false, reason: '不能移动到自己的后代下面（会形成环）');
  }
  if (!index.fitsDepthLimit(nodeId, newParentId, maxDepth)) {
    return MoveCheck(allowed: false, reason: '会超过 $maxDepth 层上限');
  }
  if (crossEvent) {
    return const MoveCheck(allowed: false, reason: '跨事件移动后必须归零父引用，不能保留原父节点');
  }
  return const MoveCheck(allowed: true, reason: null);
}

/// 项目嵌套深度上限（Q27：根 = 第 1 层）。
const int maxProjectDepth = 3;

/// 任务树深度上限（不含 Event，ADR-060）。
const int maxTaskDepth = 3;
