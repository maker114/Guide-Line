import '../models/entity.dart';
import '../models/enums.dart';
import '../models/event.dart';
import '../models/inspiration.dart';
import '../models/project.dart';
import '../models/task.dart';
import '../tree/tree_index.dart';

/// 归档区（ADR-052）。
///
/// **所有「从主视图消失」的东西必须有唯一去处**。归档区不是新实体，
/// 而是由既有字段（`archived` / `status` / `deleted`）推导出的**视图聚合**。
///
/// 分区：
///   已归档 / 已丢弃 / 已合并 / 回收站（+ 本地草稿由 UI 直接读本地目录）
class ArchiveZone {
  const ArchiveZone({
    required this.archivedRoots,
    required this.discardedInspirations,
    required this.mergedInspirations,
    required this.trashRoots,
    required this.hiddenInspirations,
  });

  static const ArchiveZone empty = ArchiveZone(
    archivedRoots: <Entity>[],
    discardedInspirations: <Entity>[],
    mergedInspirations: <Entity>[],
    trashRoots: <Entity>[],
    hiddenInspirations: <Entity>[],
  );

  /// 已归档：只列**归档根**（父未归档者），避免列表爆炸。
  final List<Entity> archivedRoots;

  final List<Entity> discardedInspirations;

  final List<Entity> mergedInspirations;

  /// 回收站：墓碑中只列**级联根**（父未被删除者）。
  final List<Entity> trashRoots;

  /// 因所在项目被归档而一并隐藏的灵感（Q53）。
  final List<Entity> hiddenInspirations;

  bool get isEmpty =>
      archivedRoots.isEmpty &&
      discardedInspirations.isEmpty &&
      mergedInspirations.isEmpty &&
      trashRoots.isEmpty;

  int get totalCount =>
      archivedRoots.length +
      discardedInspirations.length +
      mergedInspirations.length +
      trashRoots.length;
}

/// 回收站**保留天数**：墓碑超过它就自动清掉（实机反馈：回收站不能无限增长）。
///
/// 清理由 `Workspace.purgeExpiredTrash()` 在**启动时**做一次 —— 没人会专门去点
/// "清理回收站"，而墓碑长期堆着只会让数据文件越来越大。
const int trashRetentionDays = 30;

/// 一条墓碑**还剩几天**被自动清掉（0 或负数 = 这次启动就该清了）。
///
/// 按**日历天**算（与界面上的日期口径一致），不是按 24 小时的整数倍：
/// 23:59 删的与次日 00:01 删的，界面上都该被看成"隔了一天"。
int trashDaysLeft(int deletedAtMillis, {DateTime? now}) {
  final deleted = DateTime.fromMillisecondsSinceEpoch(deletedAtMillis);
  final current = now ?? DateTime.now();
  final elapsed = DateTime.utc(current.year, current.month, current.day)
      .difference(DateTime.utc(deleted.year, deleted.month, deleted.day))
      .inDays;
  return trashRetentionDays - elapsed;
}

ArchiveZone deriveArchiveZone({
  required Iterable<Project> projects,
  required Iterable<Event> events,
  required Iterable<Task> tasks,
  required Iterable<Inspiration> inspirations,
}) {
  final nodes = <EntityNode>[
    ...projects,
    ...events,
    ...tasks,
  ];
  final index = TreeIndex(nodes);
  final eventsById = <String, Event>{for (final e in events) e.id: e};

  // 「级联根」判定必须把**主线任务**也算进来：主线任务的 `parent_task_id` 为空，
  // 它真正的归属是**事件**。只看 `parentId` 会把「事件已归档」的整条任务线
  // 逐条当成根列出来（归档一个事件，归档区冒出四五条），而单独取消其中一条
  // 根本没意义 —— 事件还归档着，它就还是看不见。归档 / 删除都以事件为准。
  bool isCascadeRoot(EntityNode node, bool Function(EntityNode) flagged) {
    final parentId = node.parentId;
    if (parentId != null) {
      final parent = index.byId[parentId];
      // 父节点不在这批节点里（悬挂引用）时仍按根处理，不让它从界面上消失
      return parent == null || !flagged(parent);
    }
    if (node is Task) {
      final owner = eventsById[node.eventId];
      return owner == null || !flagged(owner);
    }
    return true;
  }

  final archivedRoots = nodes
      .where((n) => !n.deleted && n.archived)
      .where((n) => isCascadeRoot(n, (node) => node.archived))
      .toList(growable: false)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  final trashRoots = nodes
      .where((n) => n.deleted)
      .where((n) => isCascadeRoot(n, (node) => node.deleted))
      .toList(growable: false)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  final discarded = <Entity>[];
  final merged = <Entity>[];
  final hidden = <Entity>[];

  final archivedProjectIds = <String>{};
  for (final n in nodes) {
    if (n is Project && n.archived && !n.deleted) archivedProjectIds.add(n.id);
  }
  // 归档项目下的灵感一并隐藏（含子项目）
  final archivedTree = <String>{};
  for (final id in archivedProjectIds) {
    for (final node in index.subtreeOf(id)) {
      archivedTree.add(node.id);
    }
  }

  for (final inspiration in inspirations) {
    if (inspiration.deleted) continue;
    switch (inspiration.status) {
      case InspirationStatus.discarded:
        discarded.add(inspiration);
        break;
      case InspirationStatus.merged:
        merged.add(inspiration);
        break;
      case InspirationStatus.pending:
        if (inspiration.projectId != null && archivedTree.contains(inspiration.projectId)) {
          hidden.add(inspiration);
        }
        break;
    }
  }
  discarded.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  merged.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  hidden.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  return ArchiveZone(
    archivedRoots: archivedRoots,
    discardedInspirations: discarded,
    mergedInspirations: merged,
    trashRoots: trashRoots,
    hiddenInspirations: hidden,
  );
}
