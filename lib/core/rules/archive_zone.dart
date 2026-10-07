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
/// 这里有**五个集合**，但界面上是**三档**（2026-09-27 合并，
/// 见《项目与事件-定义与边界》§1.1）：三个灵感集合在「已处理的灵感」那一档里
/// 合流，逐条按来源打标记 —— 所以这里的字段划分是**取数口径**，不是界面分档。
///
///   已归档 / 已丢弃 / 已合并 / 回收站 / 被隐藏
///
/// 三个灵感集合里，**丢弃与合并只留 [processedRetentionDays] 天**（2026-10-07 定），
/// 到期的不进这一档、由启动时那次清理骨架化；「被隐藏」是**算出来的**、没有保留期。
///
/// （历史注释里写过"本地草稿由 UI 直接读本地目录"：那个分区**从未实现**，
///   移动端没有草稿实体，这一句已经删掉，免得后来的人去找一个不存在的东西。）
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

/// 「已处理的灵感」**保留天数**（ADR-098，2026-10-07 用户要求：
/// **已处理的灵感改为保存 30 天**）。
///
/// 清理由 `Workspace.purgeExpiredInspirations()` 在**启动时**做一次，与回收站同一时机。
/// 从前丢弃 / 合并过的灵感**无限期留着** —— 归档区那一档只增不减，
/// 而它的原始去向（重新决定归属、恢复为待处理）九成在头几天就已经做完了。
const int processedRetentionDays = 30;

/// 按**日历天**算还剩几天到期（0 或负数 = 这次启动就该清了）。
///
/// 为什么用日历天而不是 24 小时的整数倍：23:59 处理的与次日 00:01 处理的，
/// 界面上都该被看成"隔了一天"。`trashDaysLeft` 与 `processedDaysLeft` 同源这一段，
/// 免得"回收站按日历天、已处理按 24 小时"这种看不见的差别长出来。
int _daysLeft(int atMillis, int retentionDays, DateTime? now) {
  final at = DateTime.fromMillisecondsSinceEpoch(atMillis);
  final current = now ?? DateTime.now();
  final elapsed = DateTime.utc(current.year, current.month, current.day)
      .difference(DateTime.utc(at.year, at.month, at.day))
      .inDays;
  return retentionDays - elapsed;
}

/// 一条墓碑**还剩几天**被自动清掉（0 或负数 = 这次启动就该清了）。
int trashDaysLeft(int deletedAtMillis, {DateTime? now}) =>
    _daysLeft(deletedAtMillis, trashRetentionDays, now);

/// 一条**已处理的灵感**（丢弃 / 合并）还剩几天被自动清掉。
///
/// 计时起点是 `updated_at` —— 丢弃与合并都会把它顶到那一刻（`Workspace` 里
/// 两个动作都带 `now`）。**「被隐藏」的那些不参与**：它们没有那个时刻，
/// 也不该因为"晾了 30 天"被清掉（见 [deriveArchiveZone]）。
int processedDaysLeft(int updatedAtMillis, {DateTime? now}) =>
    _daysLeft(updatedAtMillis, processedRetentionDays, now);

ArchiveZone deriveArchiveZone({
  required Iterable<Project> projects,
  required Iterable<Event> events,
  required Iterable<Task> tasks,
  required Iterable<Inspiration> inspirations,
  DateTime? now,
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
        // 到期的**不进这一档**：它已经超过 [processedRetentionDays]，
        // 启动时那次清理（`Workspace.purgeExpiredInspirations`）会让它只剩一条墓碑。
        // 两处必须同一判据 —— 归档区列出来、清理又照清，用户会看到"点不动的一条"。
        if (processedDaysLeft(inspiration.updatedAt, now: now) <= 0) break;
        discarded.add(inspiration);
        break;
      case InspirationStatus.merged:
        if (processedDaysLeft(inspiration.updatedAt, now: now) <= 0) break;
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
