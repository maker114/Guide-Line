// 契约枚举（《数据契约》§4.1）。
//
// 铁律：
//   · 线上取值全小写、大小写敏感；
//   · `NodeStatus` 与 `InspirationStatus` 同名不同义，禁止共用解析器；
//   · 未知取值一律降级并记录问题，绝不抛异常中断同步。

/// 树形实体（Project / Event / Task）的三态。
enum NodeStatus {
  pending,
  done,
  ignored;

  String get wire => name;

  static NodeStatus fromWire(Object? value, void Function(String)? onIssue) {
    switch (value) {
      case 'pending':
        return NodeStatus.pending;
      case 'done':
        return NodeStatus.done;
      case 'ignored':
        return NodeStatus.ignored;
      default:
        onIssue?.call('未知 NodeStatus：$value —— 降级为 pending');
        return NodeStatus.pending;
    }
  }
}

/// 灵感的三态（与树形实体**语义不同**）。
enum InspirationStatus {
  pending,
  merged,
  discarded;

  String get wire => name;

  static InspirationStatus fromWire(Object? value, void Function(String)? onIssue) {
    switch (value) {
      case 'pending':
        return InspirationStatus.pending;
      case 'merged':
        return InspirationStatus.merged;
      case 'discarded':
        return InspirationStatus.discarded;
      default:
        onIssue?.call('未知 InspirationStatus：$value —— 降级为 pending');
        return InspirationStatus.pending;
    }
  }
}

/// 任务的渲染角色（ADR-053：允许的父子组合受约束）。
enum TaskType {
  standard,
  subtask,
  parallel;

  String get wire => name;

  static TaskType fromWire(Object? value, void Function(String)? onIssue) {
    switch (value) {
      case 'standard':
        return TaskType.standard;
      case 'subtask':
        return TaskType.subtask;
      case 'parallel':
        return TaskType.parallel;
      default:
        onIssue?.call('未知 TaskType：$value —— 降级为 subtask');
        return TaskType.subtask;
    }
  }
}

/// 四份文档（与本地文件名一致，见《数据契约》§5）。
enum DocName {
  projects('projects.json'),
  inspirations('inspirations.json'),
  events('events.json'),
  tasks('tasks.json');

  const DocName(this.fileName);

  final String fileName;

  static DocName? fromFileName(String name) {
    for (final doc in DocName.values) {
      if (doc.fileName == name) return doc;
    }
    return null;
  }
}
