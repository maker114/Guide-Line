import '../core/ids.dart';
import '../core/models/enums.dart';
import '../core/models/project_item.dart';
import '../core/models/task.dart';
import 'workspace_state.dart';

/// 任务内部的**待办清单**（检查清单）那一块业务（《数据契约》§3.4.2）。
///
/// ## 它是什么
///
/// 一条任务下面可以再列几条细则，就是"这件事具体要做的几步"。它与**子任务**
/// 是两回事，这是整块业务的分界线：
///
/// | | 子任务（`Task.parentId != null`） | 待办（`Task.checklist`） |
/// |---|---|---|
/// | 是不是一条任务 | 是（有 id、状态、到期日、能挂自己的一层） | **不是**，只是任务里的一个数组 |
/// | 参与完成判定 | **是**（`checkEventCompletion` / `isTaskBlocked` 都看它） | **否**，一个字都不参与 |
/// | 状态 | 三态（含"已搁置"） | **两态**（勾 / 不勾） |
/// | 到期日 | 自己有一个 | **继承宿主任务**，没有自己的 |
/// | 归档 / 回收站 | 级联、可恢复 | 跟着任务走，自己不单独进归档区 |
///
/// ## 四条刻意的边界（改之前先读这里）
///
///   · **不参与任何业务判定**。勾完所有待办**不会**把任务变成 `done`；
///     待办没勾完也**不阻塞**任务完成 —— 判定只认子任务与主线节点。
///     这是刻意的：一旦待办能左右任务，`ignored`（搁置）在待办里没有对应表达，
///     四态与二态就会各说各话；
///   · **仅两态**。"这条不做了"用**删除**表达（与项目清单同一条口径：
///     条目是轻量内容，误删重打一句就好，删除**不弹二次确认**）；
///   · **顺序 := 数组下标**。条目**没有 `order` 字段** —— 与项目清单同一条口径；
///   · **只动宿主任务**。每次改动只更新那一条任务（`updatedAt` + 落盘）：
///     任务的 `status`、它的子任务、事件的状态**一律不碰**，
///     也不触发"已完成父节点退回"那条反向传播。
///
/// ## 为什么单独一个文件
///
/// 与 `workspace_checklist.dart` 同一个理由（《workspace-拆分-结论》§3 方向 A）：
/// 判据是**内聚** —— 这一块只读写任务的 `checklist` 字段，与项目、事件、灵感、
/// 归档都不相干。门面 [Workspace] 仍然保留**同名同签名**的一层壳，方法体是转发。
///
/// ## 它需要外面的两样东西
///
///   · [WorkspaceState] —— 文档集合、`upsert` 那条底层通道、以及落盘；
///   · 一个 `(String) -> Task?` 的查任务函数（门面里的 `findTask`）。
///     **不传整个 `Workspace` 进来**，理由与清单那块一样：那会把刚切开的耦合
///     接回去，还会绕成循环依赖。
class WorkspaceTaskChecklist {
  WorkspaceTaskChecklist(this._state, this._findTask);

  final WorkspaceState _state;

  /// 查一条**未删除**的任务；查不到或已删除时返回 `null`。
  final Task? Function(String taskId) _findTask;

  // ---------------------------------------------------------------- 读

  /// 这条任务的待办条目。任务不存在（或已删除）时给空表 ——
  /// **读取不抛异常**：列表页每帧都会问一次，抛异常等于让一行脏数据炸掉整页。
  List<ProjectItem> taskChecklistOf(String taskId) {
    final task = _findTask(taskId);
    if (task == null || task.deleted) return const <ProjectItem>[];
    return task.checklist;
  }

  /// 已完成 / 总数。给"待办 2/5"这类摘要用。
  ///
  /// 摘要口径与界面一致：**分母是现有条目数**，不做任何过滤（待办没有"归档"
  /// 这种状态，所以这里不需要像子任务那样排除已归档的那批）。
  ({int done, int total}) taskChecklistSummary(String taskId) {
    final items = taskChecklistOf(taskId);
    var done = 0;
    for (final item in items) {
      if (item.done) done += 1;
    }
    return (done: done, total: items.length);
  }

  // ---------------------------------------------------------------- 写

  /// 加一条待办，返回新建的条目（调用方拿它的 id 继续做别的）。
  ///
  /// 追加在**末尾**：待办是细则，顺序就是用户列出来的顺序。
  ProjectItem addTaskChecklistItem(String taskId, String text) {
    final task = requireTask(taskId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('待办内容不能为空');

    final item = ProjectItem(id: Ids.uuidV4(), text: trimmed, done: false);
    _writeChecklist(task, <ProjectItem>[...task.checklist, item]);
    return item;
  }

  /// 改一条待办的文字（空文本拒绝；**与原来一模一样时不落盘**）。
  void updateTaskChecklistItemText(String taskId, String itemId, String text) {
    final task = requireTask(taskId);
    final index = itemIndex(task, itemId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('待办内容不能为空');
    if (task.checklist[index].text == trimmed) return; // 没变就不写盘

    final next = <ProjectItem>[...task.checklist];
    next[index] = next[index].copyWith(text: trimmed);
    _writeChecklist(task, next);
  }

  /// 勾上 / 取消一条。
  ///
  /// **这是这一块唯一会连带别的东西的地方，而它连带的是零**：任务的状态、
  /// 子任务、事件状态都不动，也不触发反向传播 —— 见类文档第一条边界。
  void setTaskChecklistItemDone(String taskId, String itemId, bool done) {
    final task = requireTask(taskId);
    final index = itemIndex(task, itemId);
    if (task.checklist[index].done == done) return; // 没变就不写盘

    final next = <ProjectItem>[...task.checklist];
    next[index] = next[index].copyWith(done: done);
    _writeChecklist(task, next);
  }

  /// 删一条待办。**不弹二次确认**（由调用方保证），条目不存在就抛。
  void removeTaskChecklistItem(String taskId, String itemId) {
    final task = requireTask(taskId);
    itemIndex(task, itemId); // 不存在就抛，避免静默什么都没发生
    _writeChecklist(
      task,
      task.checklist.where((i) => i.id != itemId).toList(growable: false),
    );
  }

  /// 清空一条任务的待办。本来就空时不落盘（与项目清单同一条守卫）。
  void clearTaskChecklist(String taskId) {
    final task = requireTask(taskId);
    if (task.checklist.isEmpty) return;
    _writeChecklist(task, const <ProjectItem>[]);
  }

  // ---------------------------------------------------------------- 内部

  /// 查到任务，查不到就抛。与 `WorkspaceChecklist.requireProject` 同一个写法：
  /// 门面里那个带下划线的 `_requireTasks` 仍然留给别的业务用，两处都是三行。
  Task requireTask(String taskId) {
    final task = _findTask(taskId);
    if (task == null || task.deleted) throw const RuleViolation('任务不存在');
    return task;
  }

  /// 条目在数组里的下标；不存在就抛（**顺序就是下标**，见类文档）。
  int itemIndex(Task task, String itemId) {
    final index = task.checklist.indexWhere((i) => i.id == itemId);
    if (index < 0) throw const RuleViolation('待办条目不存在');
    return index;
  }

  /// 写下这一批条目（**整份替换任务的 `checklist`**），然后落盘。
  ///
  /// `updatedAt` 由这里统一给：待办的每一次改动都算那条任务被改过。
  /// 这也让"改动看得见"这条与别处一致 —— 同步差异面板按 `updated_at`
  /// 认出这次改动发生在哪条任务上。
  void _writeChecklist(Task task, List<ProjectItem> items) {
    _state.upsert(
      DocName.tasks,
      task.copyWith(checklist: items, updatedAt: Ids.nowMillis()),
    );
    _state.persist();
  }
}
