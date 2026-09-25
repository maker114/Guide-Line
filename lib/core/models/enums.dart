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
///
/// **现在只有两种是"活"的**：`standard`（主线节点）与 `subtask`（框内的子任务）。
///
/// `parallel` 是**历史取值**：当年用来表达"框内并排的两条线"，这套建模
/// 以及后来替代它的**走向边**（`next_task_ids`，分叉 / 合流）都已经删掉 ——
/// 一条线就是一件事的脉络，两件并行的事请开两个事件。
///
/// 它仍然留在枚举里，是因为《数据契约》§7 明确规定**禁止删除枚举值**：
/// 老数据里还有这种任务，删掉就会在读入时被降级、下次保存时被静默改写成别的类型。
///
/// 所以：新数据**不再产生** `parallel`（`Workspace.createTask` / `updateTask`
/// 都会拒绝），但读老文件时照旧解析出来，并按子任务的样子渲染。
enum TaskType {
  standard,
  subtask,
  parallel;

  String get wire => name;

  /// 还能不能新建出来的类型 —— 界面与写入层都按它判断。
  bool get isCreatable => this != TaskType.parallel;

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

/// 四类集合。
///
/// `key` 是**单文件存储里 `collections` 的键**（`projects` / `inspirations` / …）；
/// `fileName` 保留给**契约样本与导出文件**使用（`projects.json` / …）。
enum DocName {
  projects('projects.json'),
  inspirations('inspirations.json'),
  events('events.json'),
  tasks('tasks.json');

  const DocName(this.fileName);

  final String fileName;

  /// 单文件里 `collections` 的键。
  String get key => name;
}
