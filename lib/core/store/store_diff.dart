import '../json/canonical.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import '../models/enums.dart';
import '../models/event.dart';
import '../models/inspiration.dart';
import '../models/project.dart';
import '../models/task.dart';

/// 两个版本之间的差异（**git 式**：一处改动 = 旧新两行相邻）。
///
/// 一处改动**仍然占两行**（旧一行、新一行，挨着）—— 这一点没变，因为"改之前是
/// 什么样"只有旧那一行答得出来。变的是颜色（2026-09-30，需求③）：改动的两行
/// **都是黄色**，红绿只留给"删除 / 新增"这两种真正动条数的动作，于是
/// "多了、少了、还是只是改了"一眼就能分开。用户明确撤回了原先的"一红一绿"。
///
/// 黄色那两行底下还会补一句**字段级**的小字（"完成状态：未完成 → 已完成"）：
/// 行本身只说"这条变了"，小字回答"变在哪" —— 灵感改了正文还是任务点了完成，
/// 不必自己逐字去比对两行文字。它不是另一套判定：用的还是同一份规范文本，
/// 只是把变了的键挑出来（[describeFieldChanges]），所以"算变过"与"说得出变在哪"
/// 永远一致。
///
/// 谁算"变过"：整条记录的**规范文本**（`Canonical.documentText`）不同即算变过 ——
/// 与落盘口径同源，不另立一套字段比对规则（另立一套迟早在某个字段上走偏）。
///
/// 界面口径（哪几种动作要摆、摆成什么样、没差别时怎么办）见 **ADR-092**，
/// 黄线与"提交码相同即覆盖"见 **ADR-093**。
enum DiffSide {
  /// **只在上个版本（基准）里有** —— 删除标红、改动标黄。
  previous,

  /// **只在下个版本（对方）里有** —— 新增标绿、改动标黄。
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

/// 一条记录里**哪个字段**变了（界面上那行小字："完成状态：未完成 → 已完成"）。
///
/// 取值已经翻成人话：三态翻成"未完成 / 已完成"、毫秒时间戳翻成日期、
/// 长文本截断、布尔翻成"是 / 否"。
class FieldChange {
  const FieldChange({
    required this.key,
    required this.label,
    required this.before,
    required this.after,
  });

  /// 规范键名（`status` / `completed_at` / …）—— 与落盘用的是同一套键。
  final String key;

  /// 给人看的中文字段名。
  final String label;

  /// 改之前的取值（已翻成人话）。
  final String before;

  /// 改之后的取值（已翻成人话）。
  final String after;

  /// 一行说明。
  String get text => '$label：$before → $after';

  @override
  String toString() => 'FieldChange($key · $text)';
}

/// 一处差异：某集合里某一条记录的某一侧。
class DiffEntry {
  const DiffEntry({
    required this.doc,
    required this.id,
    required this.label,
    required this.side,
    required this.kind,
    this.changes = const <FieldChange>[],
  });

  final DocName doc;
  final String id;

  /// 展示用的名字（项目标题 / 事件名 / 任务标题 / 灵感正文；墓碑另说）。
  final String label;

  final DiffSide side;
  final DiffKind kind;

  /// 改动这一处**变在哪**（只有 [DiffKind.modified] 才非空）。
  ///
  /// 改动的那一对（旧 / 新）挂着**同一份**说明：它描述的是"这条记录从旧到新"，
  /// 不属于其中哪一行。界面上只在其中一行底下写一次。
  final List<FieldChange> changes;

  bool get isAdded => side == DiffSide.next;

  /// 这一处说不说得出"改了什么"。
  ///
  /// 为空只有一种情形：两边规范文本不同、但**每一个键都比得出来且一样**
  /// （实际只可能是 `updated_at` 这种被刻意排除的噪声键在变）。界面这时
  /// 只说"内容有改动"，绝不编一句假说明。
  bool get hasChanges => changes.isNotEmpty;
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

  void add(
    Entity entity,
    DiffSide side,
    DiffKind kind, [
    List<FieldChange> changes = const <FieldChange>[],
  ]) =>
      entries.add(DiffEntry(
        doc: name,
        id: entity.id,
        label: labelOf(entity),
        side: side,
        kind: kind,
        changes: changes,
      ));

  // 先按**上个版本**的顺序走：改动的旧新两行相邻，且旧在前（与 git 一致）
  for (final old in baseItems) {
    final fresh = targetById[old.id];
    if (fresh == null) {
      add(old, DiffSide.previous, DiffKind.removed);
      continue;
    }
    if (_sameRecord(old, fresh)) continue;
    final changes = describeFieldChanges(old, fresh);
    add(old, DiffSide.previous, DiffKind.modified, changes);
    add(fresh, DiffSide.next, DiffKind.modified, changes);
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
    Tombstone _ => '已彻底删除',
    _ => '',
  };
  final trimmed = raw.trim();
  return trimmed.isEmpty ? '无标题' : trimmed;
}

// ---------- 改动说明（需求③：黄色那两行底下的小字） ----------

/// 必然跟着变、说了等于没说的键。
///
/// `updated_at` 是唯一的真例外：任何一次改动都会把它顶掉，报出来只会把真正
/// 变了的字段挤到第二行去（界面上最多写两条）。`id` 两边必然一样（差异是按 id
/// 配对的），列进来只是省得哪天有人改了配对口径。
const Set<String> _noisyKeys = <String>{'updated_at', 'id'};

/// 字段 → 中文名。四类集合共用一份 —— 键名不冲突（项目 / 任务叫 `title`，
/// 事件叫 `name`，灵感叫 `text`）。表里没有的键**如实报键名**，不猜。
const Map<String, String> _fieldLabels = <String, String>{
  'title': '标题',
  'name': '名称',
  'text': '正文',
  'purpose': '目的',
  'implementation': '做法',
  'date': '日期',
  'status': '状态',
  'task_type': '类型',
  'archived': '已归档',
  'deleted': '已删除',
  'order': '排序',
  'color': '颜色',
  'due_at': '截止日期',
  'completed_at': '完成时间',
  'created_at': '创建时间',
  'updated_at': '更新时间',
  'merged_at': '合并时间',
  'merged_into': '合并去向',
  'event_id': '所属事件',
  'parent_task_id': '上级任务',
  'parent_project_id': '上级项目',
  'project_id': '关联项目',
  'tags': '标签',
  'items': '清单',
};

/// 闭集取值的中文说法。
///
/// `pending` 在两边意思不同（树形实体是"未完成"、灵感是"未整理"），
/// 所以三态**分成两张表** —— 一个 `pending` 走错表就会说出反话（契约 §4.1
/// 那句"同名不同义，禁止共用解析器"就是说这个）。
const Map<String, String> _nodeStatusWords = <String, String>{
  'pending': '未完成',
  'done': '已完成',
  'ignored': '已忽略',
};

const Map<String, String> _inspirationStatusWords = <String, String>{
  'pending': '未整理',
  'merged': '已合并',
  'discarded': '已丢弃',
};

const Map<String, String> _taskTypeWords = <String, String>{
  'standard': '独立任务',
  'subtask': '子任务',
  'parallel': '并行，历史取值',
};

/// 同一条记录里**哪些字段变了**（按键名排序，顺序稳定）。
///
/// 与 `_sameRecord` 读的是同一份规范 JSON，所以"算变过"与"说得出变在哪"
/// 不可能打架：说变过就一定能列出至少一个键（除非变的只有 [_noisyKeys]，
/// 那时返回空表，界面只说"内容有改动"，不编假说明）。
List<FieldChange> describeFieldChanges(Entity before, Entity after) {
  final old = before.toJson();
  final fresh = after.toJson();
  final keys = <String>{...old.keys, ...fresh.keys}.toList()..sort();
  final out = <FieldChange>[];
  for (final key in keys) {
    if (_noisyKeys.contains(key)) continue;
    if (_sameValue(old[key], fresh[key])) continue;
    out.add(FieldChange(
      key: key,
      label: _fieldLabels[key] ?? key,
      before: _formatFieldValue(before, key, old[key]),
      after: _formatFieldValue(after, key, fresh[key]),
    ));
  }
  return out;
}

/// 两个 JSON 取值算不算一样（走规范文本，与"算变过"同一把尺子）。
bool _sameValue(Object? a, Object? b) {
  if (identical(a, b)) return true;
  return Canonical.documentText(a) == Canonical.documentText(b);
}

/// 一个取值写成给人看的样子。
String _formatFieldValue(Entity entity, String key, Object? value) {
  if (value == null) return '空';
  if (value is bool) return value ? '是' : '否';
  if (value is String) {
    if (value.isEmpty) return '空';
    return _wordFor(entity, key, value) ?? _clip(value);
  }
  if (value is num) {
    if (_isStamp(key)) return _stamp(value.toInt());
    return value.toString();
  }
  if (value is List) return value.isEmpty ? '空' : '${value.length} 项';
  if (value is Map) return value.isEmpty ? '空' : '${value.length} 项';
  return value.toString();
}

String? _wordFor(Entity entity, String key, String value) {
  if (key == 'status') {
    final words = entity is Inspiration ? _inspirationStatusWords : _nodeStatusWords;
    return words[value];
  }
  if (key == 'task_type') return _taskTypeWords[value];
  return null;
}

/// 毫秒时间戳的键 —— 写成日期比写一串数字有用。
bool _isStamp(String key) =>
    key == 'created_at' ||
    key == 'updated_at' ||
    key == 'completed_at' ||
    key == 'merged_at' ||
    key == 'purged_at';

String _stamp(int millis) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 长文本截断：那行小字是"提示"，全文就在它上面那两行里。
String _clip(String text) {
  final trimmed = text.trim();
  if (trimmed.length <= 24) return trimmed;
  return '${trimmed.substring(0, 24)}…';
}
