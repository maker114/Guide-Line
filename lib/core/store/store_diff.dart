import '../json/canonical.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import '../models/enums.dart';
import '../models/event.dart';
import '../models/inspiration.dart';
import '../models/project.dart';
import '../models/task.dart';

/// 两个版本之间的差异（**git 式**：一处改动 = 先删后增两行）。
///
/// 为什么不做"字段级 diff"（只说改了哪几个字段）：用户要的是**一眼看出两个版本
/// 差在哪**。git 的 `diff` 用的就是这一套 —— 红的是上个版本那一行、绿的是下个版本
/// 那一行，同一处改动在屏幕上是**挨着的一对**；字段级 diff 反而要人自己在两个值
/// 之间做差，还容易漏看"完成态翻了个面"这种只有一位的改动。
///
/// 谁算"变过"：整条记录的**规范文本**（`Canonical.documentText`）不同即算变过 ——
/// 与落盘口径同源，不另立一套字段比对规则（另立一套迟早在某个字段上走偏）。
///
/// 界面口径（哪四种动作要摆、摆成什么样、没差别时怎么办）见 **ADR-092**。
enum DiffSide {
  /// **只在上个版本（基准）里有** —— 界面上标红。
  previous,

  /// **只在下个版本（对方）里有** —— 界面上标绿。
  next,
}

/// 这一处差异是哪一类。
///
/// 与 [DiffSide] 正交：[DiffSide] 说"这一行在屏幕上是红还是绿"，[DiffKind] 说
/// "这处差异是新增、删除还是改动"。分开是因为**提问不同** —— 界面只关心红绿，
/// 而"我这一推会不会把云端的东西推没了"只认 [DiffKind.removed]（真的没了），
/// 不能把"同一条记录被本机版本顶掉"也算成丢东西。
enum DiffKind {
  /// 只有下个版本有这条记录。
  added,

  /// 只有上个版本有这条记录（对方那边**整个 id 都不在了**）。
  removed,

  /// 两个版本都有这个 id，但内容不同（成对出现：红旧 + 绿新）。
  modified,
}

/// 一处差异：某集合里某一条记录的某一侧。
class DiffEntry {
  const DiffEntry({
    required this.doc,
    required this.id,
    required this.label,
    required this.side,
    required this.kind,
  });

  final DocName doc;
  final String id;

  /// 展示用的名字（项目标题 / 事件名 / 任务标题 / 灵感正文；墓碑另说）。
  final String label;

  final DiffSide side;
  final DiffKind kind;

  bool get isAdded => side == DiffSide.next;

  bool get isRemoved => side == DiffSide.previous;
}

/// 一个集合的差异。
class CollectionDiff {
  const CollectionDiff({required this.doc, required this.entries});

  final DocName doc;

  /// 已排好序：先按**上个版本**的顺序成对给出改动/删除，再追加只有下个版本有的。
  final List<DiffEntry> entries;

  int get added =>
      entries.where((e) => e.kind == DiffKind.added).length;

  int get removed =>
      entries.where((e) => e.kind == DiffKind.removed).length;

  /// 改动条数（一对红绿算**一处**）。
  int get modified => entries
      .where((e) => e.kind == DiffKind.modified && e.isAdded)
      .length;

  bool get hasChanges => entries.isNotEmpty;
}

/// 两个版本之间的全部差异（四个集合都在，界面上自行挑有变化的显示）。
class StoreDiff {
  const StoreDiff(this.collections);

  final Map<DocName, CollectionDiff> collections;

  CollectionDiff of(DocName name) =>
      collections[name] ?? CollectionDiff(doc: name, entries: const <DiffEntry>[]);

  /// 有变化的集合，按 [DocName] 的固定顺序。
  Iterable<CollectionDiff> get changed =>
      DocName.values.map(of).where((c) => c.hasChanges);

  int get added =>
      DocName.values.fold(0, (sum, name) => sum + of(name).added);

  int get removed =>
      DocName.values.fold(0, (sum, name) => sum + of(name).removed);

  int get modified =>
      DocName.values.fold(0, (sum, name) => sum + of(name).modified);

  bool get hasChanges => added > 0 || removed > 0 || modified > 0;

  /// 基准那一侧**有没有整条记录会不见**。
  ///
  /// 上传前用它回答那个唯一要紧的问题："我这一推，会不会把云端上有的东西推没了？"
  /// 会 —— 就不能不打招呼地推（ADR-088：冲突只判定、不自动合并）。
  /// 只看 [removed]：同一条记录被本机版本顶掉属于"两边都动过这一条"，
  /// 由冲突判定去管，不算"推没了一整条"。
  bool get dropsFromBase => removed > 0;

  String get changeSummary => '新增 $added · 删除 $removed · 修改 $modified';
}

/// 算差异：[base] 是**上个版本**（旧），[target] 是**下个版本**（新）。
///
/// 调用方决定谁当基准 —— 看云端差异时 `base = 本机`（红的是本机将被换掉的），
/// 上传前检查时 `base = 云端`（红的是云端将被覆盖掉的）。
StoreDiff diffStores({required StoreFile base, required StoreFile target}) {
  final out = <DocName, CollectionDiff>{};
  for (final name in DocName.values) {
    out[name] = _diffCollection(
      name,
      base.documentOf(name).items,
      target.documentOf(name).items,
    );
  }
  return StoreDiff(out);
}

CollectionDiff _diffCollection(
  DocName name,
  List<Entity> baseItems,
  List<Entity> targetItems,
) {
  final baseById = _indexById(baseItems);
  final targetById = _indexById(targetItems);
  final entries = <DiffEntry>[];

  void add(Entity entity, DiffSide side, DiffKind kind) =>
      entries.add(DiffEntry(
        doc: name,
        id: entity.id,
        label: labelOf(entity),
        side: side,
        kind: kind,
      ));

  // 先按**上个版本**的顺序走：改动的红绿成对相邻，且红在前（与 git 一致）
  for (final old in baseItems) {
    final fresh = targetById[old.id];
    if (fresh == null) {
      add(old, DiffSide.previous, DiffKind.removed);
      continue;
    }
    if (_sameRecord(old, fresh)) continue;
    add(old, DiffSide.previous, DiffKind.modified);
    add(fresh, DiffSide.next, DiffKind.modified);
  }
  // 再追加只有下个版本有的（按对方自己的顺序）
  for (final fresh in targetItems) {
    if (baseById.containsKey(fresh.id)) continue;
    add(fresh, DiffSide.next, DiffKind.added);
  }
  return CollectionDiff(doc: name, entries: entries);
}

Map<String, Entity> _indexById(List<Entity> items) {
  final out = <String, Entity>{};
  for (final item in items) {
    out.putIfAbsent(item.id, () => item);
  }
  return out;
}

/// 同一 id 的两条记录算不算"没变过"：比**规范文本**（与落盘同一出口）。
bool _sameRecord(Entity a, Entity b) =>
    Canonical.documentText(a.toJson()) == Canonical.documentText(b.toJson());

/// 展示用名字。墓碑没有标题 —— 如实说"已彻底删除"，不拿 id 充数。
String labelOf(Entity entity) {
  final raw = switch (entity) {
    final Project project => project.title,
    final Event event => event.name,
    final Task task => task.title,
    final Inspiration inspiration => inspiration.text,
    Tombstone _ => '（已彻底删除）',
    _ => '',
  };
  final trimmed = raw.trim();
  return trimmed.isEmpty ? '（无标题）' : trimmed;
}
