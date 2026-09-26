// 「合并导入」的纯逻辑内核（《修改计划总表》Q25）。
//
// 场景：**换手机、或两台设备各记了一部分**。Q13 那条导入路是"整份替换"，
// 会把另一头那几天的记录抹掉；这里要的是"两份并成一份"。
//
// 三条定死的规则（改口径要连着改这份注释与测试，别只改代码）：
//   1. **记录键 = `id`，逐集合独立**（projects / inspirations / events / tasks
//      各合各的）—— 同名不同集合的记录互不影响，四类实体之间也没有先后依赖；
//   2. 同 `id` 两边都有 → 取**较新**的一方：普通记录看 `updated_at`，
//      墓碑骨架看 `purged_at`（契约 §3.5 只有这三个 key）；**两者相等时保留
//      "当前库"那一份**（本地为准）—— 同一秒里的抖动不该把用户手上正在看的
//      记录换成另一份，宁可"没合并到"，也不要"看起来没变却换了内容"；
//   3. 只有一边有的记录**直接并入，墓碑也并入**。这条最容易被"顺手清理"掉：
//      在另一台设备上删掉的记录，如果合并时把它的墓碑丢了，下次同步 / 导入
//      就会**复活**它（墓碑是"删过"这件事的唯一证据）。
//
// 「取较新的一方」取的是一整条记录：**落败那一方的 `extra` 额外键不会并进来**。
// 一条记录是原子的，拼一份"半新半旧"的记录比丢一个未知键更糟（也给不出
// "哪个字段听谁的"的一致口径）。胜出方自己带的未知键照旧透传，不受影响。
//
// 为什么是纯函数：合并结果要先拿给用户看（"多进来 12 条、覆盖 3 条"），
// 确认之后才落盘。写文件是调用方（`AppStorage.save`）的事，这里不碰文件、
// 不改入参对象。
//
// 序列化形态**一个字段都不自己拼**：记录原样复用实体对象，外层复用
// `Document` / `StoreFile` / `toCanonicalText()` —— 字段顺序、可空字段写 `null`、
// "空即省略"（`tags` / `color` / `items`）与未知字段透传（`extra`）全都与平时
// 走的是同一条路，不需要在这里再实现一遍，也不会两处走偏。
//
// **引用悬挂不在这里修**：合并后可能留下"指向已缺失记录"的引用（例如本地项目
// 的 `parent_project_id` 指向对方文件里没有的项目）。契约 §4.3 / §8 把悬挂的
// 处理交给加载层，这里只**报数**（`MergeReport.danglingReferences`），
// 让界面能提一句；当场改数据会把"另一台设备上还会补上这条记录"这种情况
// 变成不可逆的改写。

import '../json/document.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import '../models/enums.dart';

/// 合并两份数据（换手机 / 两台设备各记了一部分时用），只返回合并后的数据文件。
///
/// 界面要的"多进来什么、覆盖了什么"请用 [mergeStoresWithReport]；这里保留最简
/// 签名，方便只关心结果的调用方不必理会报告。
///
/// `nowMillis` 写进结果的 `savedAt`：那是"本次落盘时间"，**仅供人看、不参与任何
/// 判定**（契约 §2.1），所以不该去猜两份文件里的哪个值更合适。
StoreFile mergeStores(
  StoreFile current,
  StoreFile incoming, {
  required int nowMillis,
}) =>
    mergeStoresWithReport(current, incoming, nowMillis: nowMillis).store;

/// 合并 + 报告（界面拿报告告诉用户"多进来什么、覆盖了什么"）。
MergeOutcome mergeStoresWithReport(
  StoreFile current,
  StoreFile incoming, {
  required int nowMillis,
}) {
  final documents = <DocName, Document>{};
  final collections = <DocName, CollectionMergeReport>{};
  var duplicates = 0;

  // 逐集合合并，并**保证四个集合齐全**：某一侧缺某个集合时按空集合处理，
  // 结果里仍然写出全部四个 `items`（契约 §2 的外层结构不能缺件）。
  for (final name in DocName.values) {
    final merged = _mergeCollection(current.documentOf(name), incoming.documentOf(name));
    documents[name] = Document(name: name, items: merged.items);
    collections[name] = merged.report;
    duplicates += merged.report.duplicatesCollapsed;
  }

  final store = StoreFile(documents: documents, savedAt: nowMillis);
  return MergeOutcome(
    store: store,
    report: MergeReport(
      collections: collections,
      danglingReferences: _countDanglingReferences(store),
      duplicatesCollapsed: duplicates,
    ),
  );
}

/// 合并结果 + 报告 —— 两者一起给，界面才能"先看清楚再落盘"。
class MergeOutcome {
  const MergeOutcome({required this.store, required this.report});

  final StoreFile store;
  final MergeReport report;
}

/// 合并报告：界面拿它告诉用户"多进来什么、覆盖了什么"。
///
/// 四类结果逐集合给出（[CollectionMergeReport.added] / `updated` / `kept` /
/// `tombstones`），另加一个 `localOnly`（本地独有、原样留着的条数）——
/// 它也必须能被说出来，否则"合并后共 N 条"对不上账。
class MergeReport {
  const MergeReport({
    required this.collections,
    this.danglingReferences = 0,
    this.duplicatesCollapsed = 0,
  });

  /// 四个集合各一份；**四个键一定都在**（`DocName.values` 每个都合过一遍）。
  final Map<DocName, CollectionMergeReport> collections;

  /// 合并后仍指向**完全不存在**的记录的引用条数。只报数、不修（见文件头注释）。
  ///
  /// 指向"存在但已删除（墓碑）"的引用**不**算进来：契约 §4.3 把那种悬挂
  /// 明确交给上层按规则处理，那是另一回事。
  final int danglingReferences;

  /// 同一侧文件里同 `id` 重复、被折叠掉的条数（契约要求 `id` 唯一；
  /// 真出现时只认第一条，但要报出来，不静默吞）。
  final int duplicatesCollapsed;

  CollectionMergeReport of(DocName name) =>
      collections[name] ?? CollectionMergeReport.empty;

  int get added => _sum((report) => report.added.length);

  int get updated => _sum((report) => report.updated.length);

  int get kept => _sum((report) => report.kept.length);

  int get tombstones => _sum((report) => report.tombstones.length);

  int get localOnly => _sum((report) => report.localOnly);

  /// 有没有"值得一提"的变化（界面据此决定要不要提示「已合并」）：
  /// 只有本地独有与"保留"时，用户手上的数据其实一条没动。
  bool get hasChanges => added > 0 || updated > 0 || tombstones > 0;

  /// 一行摘要，写法与 `ExportPayload.countSummary` 一致，界面可以直接显示。
  String get changeSummary => '新增 $added · 更新 $updated · 保留 $kept · 墓碑 $tombstones';

  int _sum(int Function(CollectionMergeReport) pick) =>
      DocName.values.fold(0, (sum, name) => sum + pick(of(name)));
}

/// 单个集合的合并结果。
///
/// 四类**互斥**：一条记录只落在其中一类里。所以
/// `added + updated + kept + tombstones + localOnly == 合并后该集合的条数`。
class CollectionMergeReport {
  const CollectionMergeReport({
    required this.added,
    required this.updated,
    required this.kept,
    required this.tombstones,
    this.localOnly = 0,
    this.duplicatesCollapsed = 0,
  });

  static const CollectionMergeReport empty = CollectionMergeReport(
    added: <Entity>[],
    updated: <Entity>[],
    kept: <Entity>[],
    tombstones: <Entity>[],
  );

  /// 对方独有、并入的**活记录**（墓碑不在这里，见 [tombstones]）。
  final List<Entity> added;

  /// 同 `id` 且对方较新：本地被**覆盖**，这里放覆盖后生效的那一份。
  final List<Entity> updated;

  /// 同 `id` 且本地不输（较新，或时间戳**相等**）：保留本地那一份，没动它。
  ///
  /// 时间戳相等 → 本地赢，这条口径写死在 [mergeStores] 的注释与测试里。
  final List<Entity> kept;

  /// 由对方**并入的墓碑骨架**（对方独有、或覆盖了本地活记录，都算这里）。
  ///
  /// 单独成一类，是因为界面要说的是「删掉了什么」；把它们混进"新增"里，
  /// 用户会以为合并多出来几条数据。
  final List<Entity> tombstones;

  /// 本地独有、没有任何一方动它的条数（只有计数：界面不需要逐条列出来）。
  final int localOnly;

  /// 本集合里同 `id` 重复被折叠掉的条数。
  final int duplicatesCollapsed;

  /// 合并后该集合的条数（四类之和，见类注释）。
  int get total =>
      added.length + updated.length + kept.length + tombstones.length + localOnly;

  bool get hasChanges => added.isNotEmpty || updated.isNotEmpty || tombstones.isNotEmpty;
}

/// 单个集合的合并：返回新列表与新报告。
_MergedCollection _mergeCollection(Document current, Document incoming) {
  final local = _indexById(current.items);
  final remote = _indexById(incoming.items);

  final items = <Entity>[];
  final added = <Entity>[];
  final updated = <Entity>[];
  final kept = <Entity>[];
  final tombstones = <Entity>[];
  var localOnly = 0;

  // 先走本地这一轮：**本地顺序原地保留**（被覆盖的记录留在它原来的位置，
  // 用户手上的列表不会因为一次合并整体重排），双方都有的在这里一次判完胜负。
  for (final entry in local.byId.entries) {
    final mine = entry.value;
    final theirs = remote.byId[entry.key];
    if (theirs == null) {
      items.add(mine);
      localOnly += 1;
      continue;
    }
    if (_isNewer(theirs, mine)) {
      items.add(theirs);
      if (theirs is Tombstone) {
        // 对方带来的删除标记：生效的是它，但归类上算"墓碑"而不是"更新"
        tombstones.add(theirs);
      } else {
        updated.add(theirs);
      }
    } else {
      items.add(mine);
      kept.add(mine);
    }
  }

  // 对方独有的追加在后面，相对次序照对方的文件：本地已有的记录位置一律不动。
  for (final entry in remote.byId.entries) {
    if (local.byId.containsKey(entry.key)) continue;
    final theirs = entry.value;
    items.add(theirs);
    if (theirs is Tombstone) {
      tombstones.add(theirs);
    } else {
      added.add(theirs);
    }
  }

  return _MergedCollection(
    items: items,
    report: CollectionMergeReport(
      added: added,
      updated: updated,
      kept: kept,
      tombstones: tombstones,
      localOnly: localOnly,
      duplicatesCollapsed: local.collapsed + remote.collapsed,
    ),
  );
}

/// 一边的记录按 `id` 建索引。
///
/// 契约要求 `id` 唯一，真出现重复时**只认第一条**：同 `id` 的"谁更新"没有第二个
/// 答案，而且结果里留着两条同 `id` 会让后面所有"按 id 找记录"出现二义性。
/// 折叠掉多少条记进报告，不静默吞。
_IdIndex _indexById(List<Entity> items) {
  final byId = <String, Entity>{};
  var collapsed = 0;
  for (final item in items) {
    if (byId.containsKey(item.id)) {
      collapsed += 1;
      continue;
    }
    byId[item.id] = item;
  }
  return _IdIndex(byId: byId, collapsed: collapsed);
}

/// 谁更新：普通记录比 `updated_at`，墓碑骨架比 `purged_at`（契约 §3.5）。
///
/// [Tombstone.updatedAt] 现在恰好就是 `purged_at` 的别名，直接比 `updatedAt` 也
/// 能得出同样结果 —— 但这里**显式按契约的字段名分叉**：墓碑的比较依据叫
/// `purged_at`，哪天那个别名变了，合并的判定不该跟着悄悄变。
bool _isNewer(Entity candidate, Entity incumbent) =>
    _freshness(candidate) > _freshness(incumbent);

int _freshness(Entity entity) =>
    entity is Tombstone ? entity.purgedAt : entity.updatedAt;

/// 数一遍"合并结果里指向缺失记录的引用"。
///
/// 只数、不改：契约 §4.3 / §8 把悬挂的处理放在加载层，合并当场改写引用会不可逆
/// （本地项目等着对方文件里那条记录来补位，改成 `null` 就再也回不来了）。
///
/// 墓碑里的 `id` 算"记录存在"—— 它还在 `items` 里（ADR-003 不物理删除），
/// 指向它的引用属于"指向已删除记录"，由上层按悬挂规则处理，不是缺失。
int _countDanglingReferences(StoreFile store) {
  final projectIds = _idsOf(store.documentOf(DocName.projects).items);
  final eventIds = _idsOf(store.documentOf(DocName.events).items);
  final taskIds = _idsOf(store.documentOf(DocName.tasks).items);

  var count = 0;
  for (final project in store.documentOf(DocName.projects).projectItems) {
    if (_isMissing(project.parentProjectId, projectIds)) count += 1;
  }
  for (final inspiration in store.documentOf(DocName.inspirations).inspirationItems) {
    if (_isMissing(inspiration.projectId, projectIds)) count += 1;
    if (_isMissing(inspiration.mergedInto, projectIds)) count += 1;
  }
  for (final task in store.documentOf(DocName.tasks).taskItems) {
    if (_isMissing(task.eventId, eventIds)) count += 1;
    if (_isMissing(task.parentTaskId, taskIds)) count += 1;
  }
  return count;
}

Set<String> _idsOf(List<Entity> items) =>
    <String>{for (final item in items) item.id};

bool _isMissing(String? id, Set<String> present) => id != null && !present.contains(id);

class _MergedCollection {
  const _MergedCollection({required this.items, required this.report});

  final List<Entity> items;
  final CollectionMergeReport report;
}

class _IdIndex {
  const _IdIndex({required this.byId, required this.collapsed});

  final Map<String, Entity> byId;
  final int collapsed;
}
