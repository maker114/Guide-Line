import 'enums.dart';

/// 反序列化过程中收集到的问题（《数据契约》§8）。
///
/// 容错原则：**能读就读，读不了就降级并记录**，绝不因为一条脏数据中断整包同步；
/// 但问题必须暴露出来，不能静默吞掉。
class DecodeIssues {
  final List<String> warnings = <String>[];
  final List<String> errors = <String>[];

  void warn(String message) => warnings.add(message);

  void error(String message) => errors.add(message);

  bool get isEmpty => warnings.isEmpty && errors.isEmpty;

  @override
  String toString() =>
      'DecodeIssues(warnings: ${warnings.length}, errors: ${errors.length})';
}

/// 所有实体的最小共同面。
abstract class Entity {
  String get id;

  bool get deleted;

  int get createdAt;

  int get updatedAt;

  /// 按《数据契约》§3 的字段顺序输出。
  Map<String, dynamic> toJson();
}

/// 参与树结构、完成判定与级联的实体共同面。
///
/// 让通用的树算法与状态机只依赖这个接口，而不关心具体是项目还是任务。
abstract class EntityNode implements Entity {
  String? get parentId;

  NodeStatus get status;

  bool get archived;

  int get order;

  int? get completedAt;
}

/// 墓碑骨架（《数据契约》§3.5）：彻底删除后只剩 3 个 key。
class Tombstone implements Entity {
  const Tombstone({required this.id, required this.purgedAt});

  @override
  final String id;

  final int purgedAt;

  @override
  bool get deleted => true;

  @override
  int get createdAt => purgedAt;

  @override
  int get updatedAt => purgedAt;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'deleted': true,
        'purged_at': purgedAt,
      };

  /// 判定一个已解析的 JSON 对象是否为墓碑骨架。
  static bool matches(Map<String, dynamic> json) {
    final keys = json.keys.toList(growable: false);
    return keys.length == 3 &&
        keys[0] == 'id' &&
        keys[1] == 'deleted' &&
        keys[2] == 'purged_at';
  }
}
