import '../models/entity.dart';
import '../models/enums.dart';
import '../models/event.dart';
import '../models/inspiration.dart';
import '../models/project.dart';
import '../models/task.dart';
import 'canonical.dart';

/// 一份**集合**（某一实体类型的全部记录）。
///
/// 手机端是单机应用，因此不再有文档级版本号 / 服务端时间戳 / 事务 ID ——
/// 那些都是为「双端同步」服务的（ADR-004）。
/// 现在只剩「一组记录」这一件事。
class Document {
  const Document({required this.name, required this.items});

  factory Document.empty(DocName name) =>
      Document(name: name, items: const <Entity>[]);

  final DocName name;
  final List<Entity> items;

  Iterable<Project> get projectItems => items.whereType<Project>();

  Iterable<Inspiration> get inspirationItems => items.whereType<Inspiration>();

  Iterable<Event> get eventItems => items.whereType<Event>();

  Iterable<Task> get taskItems => items.whereType<Task>();

  /// 序列化形态：**只有 `items`**。单条记录的字段顺序仍由《数据契约》约束。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(growable: false),
      };

  /// 落盘文本：与 `test/contract/sample/<name>.json` 逐字节一致。
  String toCanonicalText() => Canonical.documentText(toJson());

  Document copyWith({List<Entity>? items}) =>
      Document(name: name, items: items ?? this.items);

  /// 解析（**容错**：单条记录损坏不影响整份集合，见《数据契约》§8）。
  static Document parse(DocName name, String text, DecodeIssues issues) {
    Object? root;
    try {
      root = Canonical.decode(text);
    } catch (error) {
      issues.error('${name.fileName} 不是合法 JSON：$error');
      return Document.empty(name);
    }

    final map = Canonical.readObject(root, '${name.fileName}.root', issues);
    if (map == null) return Document.empty(name);
    return fromJsonMap(name, map, issues);
  }

  /// 从已解析的 map 构造（单文件里每份集合就是这样一个对象）。
  static Document fromJsonMap(
    DocName name,
    Map<String, dynamic> map,
    DecodeIssues issues,
  ) {
    final rawItems = Canonical.readArray(map['items'], '${name.fileName}.items', issues);
    final items = <Entity>[];
    if (rawItems != null) {
      for (var i = 0; i < rawItems.length; i += 1) {
        final raw = Canonical.readObject(rawItems[i], '${name.fileName}.items[$i]', issues);
        if (raw == null) continue;
        final parsed = parseItem(name, raw, i, issues);
        if (parsed != null) items.add(parsed);
      }
    }
    return Document(name: name, items: items);
  }

  /// 按集合类型分发到对应实体；**墓碑骨架优先识别**（《数据契约》§3.5）。
  static Entity? parseItem(
    DocName name,
    Map<String, dynamic> raw,
    int index,
    DecodeIssues issues,
  ) {
    if (Tombstone.matches(raw)) {
      final id = Canonical.readString(raw['id'], '${name.fileName}.items[$index].id', issues);
      final purgedAt =
          Canonical.readInt(raw['purged_at'], '${name.fileName}.items[$index].purged_at', issues);
      if (id == null || purgedAt == null) {
        issues.error('${name.fileName}.items[$index]：墓碑骨架缺少 id / purged_at，已丢弃');
        return null;
      }
      return Tombstone(id: id, purgedAt: purgedAt);
    }

    switch (name) {
      case DocName.projects:
        return Project.fromJson(raw, issues);
      case DocName.inspirations:
        return Inspiration.fromJson(raw, issues);
      case DocName.events:
        return Event.fromJson(raw, issues);
      case DocName.tasks:
        return Task.fromJson(raw, issues);
    }
  }
}
