import '../json/canonical.dart';
import 'entity.dart';

/// 项目「实现」里的一条**实现清单条目**（《数据契约》§3.2.1）。
///
/// 三条刻意的边界，写在最前面免得后来的人改错：
///   · **不参与任何业务判定** —— 勾选只是"打勾了"。项目没有完成态
///     （《定义与边界》§2.1），归档级联也与这里无关；
///   · **与事件里的任务没有任何联动** —— 任务有走向与完成判定，
///     清单只是"这个项目打算怎么做"的备忘录。联动会出现"项目里勾了、
///     任务线那边没动"的矛盾，所以刻意不做；
///   · **没有 `order` 字段** —— 顺序就是它在数组里的下标。任务存 `order`
///     是因为要跨父节点排序并兼容老数据的隐式链；这里是一维列表，
///     再存一个顺序只会多一处能不一致的地方。
class ProjectItem {
  const ProjectItem({
    required this.id,
    required this.text,
    required this.done,
    this.extra = const <String, dynamic>{},
  });

  static const Set<String> knownKeys = <String>{'id', 'text', 'done'};

  /// 条目自己的身份 —— 原地编辑、删除、上移下移都按它找。
  final String id;

  /// 条目正文。写入时必须是 `trim()` 后非空的。
  final String text;

  /// 是否已打勾。
  final bool done;

  /// 未知字段透传（契约 §8）：条目里出现的额外键原样保留，
  /// 免得"读进来再写出去"把它们抹掉。
  final Map<String, dynamic> extra;

  ProjectItem copyWith({String? text, bool? done}) {
    return ProjectItem(
      id: id,
      text: text ?? this.text,
      done: done ?? this.done,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'done': done,
        ...extra,
      };

  @override
  bool operator ==(Object other) =>
      other is ProjectItem && other.id == id && other.text == text && other.done == done;

  @override
  int get hashCode => Object.hash(id, text, done);

  @override
  String toString() => 'ProjectItem($id, done=$done, $text)';
}

/// 逐条解析清单。
///
/// **坏条目只丢它自己**，不让整个项目解析失败 —— 一条清单坏掉就丢掉整个项目
/// 是不可接受的降级。容错口径与契约 §8 一致：记 error，但不抛异常。
///
/// 与 `Canonical.readStringList` 的区别：那个是"字符串数组"，会把空串静默丢掉；
/// 这里是**对象数组**，而且"文字为空"应该由写入层拒绝（`RuleViolation`），
/// 读取时遇到就直接跳过并记错，免得界面上出现一条点不动的空条目。
List<ProjectItem> readProjectItems(Object? value, String field, DecodeIssues issues) {
  if (value == null) return const <ProjectItem>[];
  if (value is! List) {
    issues.error('$field 期望 array，实际 ${value.runtimeType} —— 按空处理');
    return const <ProjectItem>[];
  }

  final out = <ProjectItem>[];
  final seenIds = <String>{};
  for (var i = 0; i < value.length; i += 1) {
    final raw = value[i];
    if (raw is! Map) {
      issues.error('$field[$i] 不是对象（${raw.runtimeType}）—— 跳过该条目');
      continue;
    }
    final map = raw is Map<String, dynamic> ? raw : raw.cast<String, dynamic>();
    final id = Canonical.readString(map['id'], '$field[$i].id', issues);
    final text = Canonical.readString(map['text'], '$field[$i].text', issues);
    if (id == null || id.isEmpty || text == null || text.trim().isEmpty) {
      issues.error('$field[$i] 缺 id 或 text 为空 —— 跳过该条目');
      continue;
    }
    if (!seenIds.add(id)) {
      // 同 id 重复会让"按 id 找条目"出现二义性，后一条丢掉
      issues.error('$field[$i] 的 id 与前面重复（$id）—— 跳过该条目');
      continue;
    }
    out.add(
      ProjectItem(
        id: id,
        text: text.trim(),
        done: Canonical.readBool(map['done'], '$field[$i].done', issues) ?? false,
        extra: Canonical.readExtra(map, ProjectItem.knownKeys),
      ),
    );
  }
  return out;
}
