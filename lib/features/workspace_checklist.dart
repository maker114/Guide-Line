import '../core/ids.dart';
import '../core/models/enums.dart';
import '../core/models/project.dart';
import '../core/models/project_item.dart';
import '../core/models/task.dart';
import 'workspace_state.dart';

/// 项目「如何解决」里的**实现清单**那一块业务（《数据契约》§3.2.1）。
///
/// ## 三条刻意的边界（改之前先读这里）
///
///   · **顺序 := 数组下标**。条目**没有 `order` 字段** —— 任务存 `order` 是为了
///     跨父节点排序并兼容老数据的隐式链；清单是一维列表，数组顺序就是顺序，
///     再存一个只会多一处能不一致的地方；
///   · **不参与任何业务判定**。`done` 只表达"打勾了"：完成规则、反向传播、
///     归档级联全部只看项目的三态；清单**全勾完也不会**把项目变成 `done`；
///   · **与事件里的任务没有任何联动**。唯一出口是用户显式点的那一下
///     「建成任务」（[createTaskFromProjectItem]）。联动会出现"项目里勾了、
///     任务线那边没动"的矛盾，所以刻意不做。
///
/// ## 为什么单独一个文件
///
/// 它是《workspace-拆分-结论》§3「方向 A」里第一个真正搬出来的业务块。
/// 判据是**内聚**：这一块只读写项目文档的 `items` 字段，与事件、任务、灵感、
/// 归档全都不相干 —— 是那个 2267 行门面里最容易切干净的一段。
///
/// 搬出去之后，[Workspace] 仍然保留**同名同签名**的方法，方法体是一行转发，
/// 所以 `lib/ui` / `lib/app` 上的调用点与 `test/` 里的用例**一行都没改**。
/// 这是"零行为改动"的实现方式：门面还在原位，只是身子搬了家。
///
/// ## 它需要外面的两样东西
///
///   · [WorkspaceState] —— 文档集合、以及"按 id 覆盖或追加"那条底层通道；
///   · 一个 `(String) -> Project?` 的查项目函数 —— 就是原来门面里的
///     `findProject`。**不传整个 `Workspace` 进来**：那等于把刚切开的耦合
///     又接回去，而且会绕成循环依赖。
///     "项目不存在"这条规则在 [requireProject] 里重新实现了一次（原来门面里
///     那个带下划线的同名方法仍然留着，给事件/任务/重置那几块用），
///     两处都是三行，比互相调用更清楚。
class WorkspaceChecklist {
  WorkspaceChecklist(this._state, this._findProject);

  final WorkspaceState _state;

  /// 查一个**未删除**的项目；查不到或已删除时返回 `null`。
  final Project? Function(String projectId) _findProject;

  // ---------------------------------------------------------------- 正文 → 清单

  /// 把一段正文按行拆成清单条目（**显式动作**，不在读取时自动拆）。
  ///
  /// 只在"清单为空"时由界面调用：把一段中文按行拆开是**不可逆的猜测**
  /// （用户可能一段就是一条），自动拆等于第一次打开就悄悄改了数据形态。
  /// 行首的 `-` / `*` / `1.` 这类记号会被去掉，空行丢弃。
  ///
  /// 是 `static`：它不碰任何状态。界面上"AI 整理成正文"那一侧也会调它。
  static List<String> splitImplementationLines(String implementation) {
    final out = <String>[];
    for (final rawLine in implementation.split('\n')) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      line = line.replaceFirst(RegExp(r'^[-*+]\s+'), '');
      line = line.replaceFirst(RegExp(r'^\d+[.)]\s+'), '');
      line = line.trim();
      if (line.isEmpty) continue;
      out.add(line);
    }
    return out;
  }

  /// 把正文按行拆成条目。**只在清单为空时允许** —— 否则会把已有条目顶掉。
  int splitImplementationIntoItems(String projectId) {
    final project = requireProject(projectId);
    if (project.items.isNotEmpty) {
      throw const RuleViolation('已经有条目了，先把清单清空再拆');
    }
    final lines = splitImplementationLines(project.implementation);
    if (lines.isEmpty) throw const RuleViolation('正文里没有可拆成条目的内容');

    _writeItems(
      project,
      <ProjectItem>[
        for (final line in lines) ProjectItem(id: Ids.uuidV4(), text: line, done: false),
      ],
    );
    return lines.length;
  }

  /// 用给定的这批文本**整体替换**清单条目（AI 拆条目那一路的落点）。
  ///
  /// 与 [addProjectItem] 的区别是"替换而不是追加"：AI 拆出来的是**这一份正文的
  /// 完整分解**，与现有条目并排会出现同一件事两遍。空文本项丢掉、重复的**保留**
  /// （用户可能真的有两件一样的事，去重是越权）。
  ///
  /// 条目一律 `done: false`：拆出来的是"打算怎么做"，不是"已经做完"。
  int replaceProjectItems(String projectId, List<String> texts) {
    final project = requireProject(projectId);
    final cleaned = <String>[];
    for (final text in texts) {
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) throw const RuleViolation('没有可写入的条目');

    _writeItems(project, <ProjectItem>[
      for (final text in cleaned) ProjectItem(id: Ids.uuidV4(), text: text, done: false),
    ]);
    return cleaned.length;
  }

  // ---------------------------------------------------------------- 单条增删改

  ProjectItem addProjectItem(String projectId, String text) {
    final project = requireProject(projectId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('条目内容不能为空');

    final item = ProjectItem(id: Ids.uuidV4(), text: trimmed, done: false);
    _writeItems(project, <ProjectItem>[...project.items, item]);
    return item;
  }

  void updateProjectItemText(String projectId, String itemId, String text) {
    final project = requireProject(projectId);
    final index = itemIndex(project, itemId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('条目内容不能为空');
    if (project.items[index].text == trimmed) return; // 没变就不写盘

    final next = <ProjectItem>[...project.items];
    next[index] = next[index].copyWith(text: trimmed);
    _writeItems(project, next);
  }

  void setProjectItemDone(String projectId, String itemId, bool done) {
    final project = requireProject(projectId);
    final index = itemIndex(project, itemId);
    if (project.items[index].done == done) return;

    final next = <ProjectItem>[...project.items];
    next[index] = next[index].copyWith(done: done);
    _writeItems(project, next);
  }

  void removeProjectItem(String projectId, String itemId) {
    final project = requireProject(projectId);
    itemIndex(project, itemId); // 不存在就抛，避免静默什么都没发生
    _writeItems(
      project,
      project.items.where((i) => i.id != itemId).toList(growable: false),
    );
  }

  /// 上移 / 下移一条。[delta] 只接受 `-1` 与 `1`；已经在两端时是空操作。
  void moveProjectItem(String projectId, String itemId, int delta) {
    if (delta != -1 && delta != 1) {
      throw const RuleViolation('一次只能上移或下移一位');
    }
    final project = requireProject(projectId);
    final index = itemIndex(project, itemId);
    final target = index + delta;
    if (target < 0 || target >= project.items.length) return; // 到头了，什么也不做

    final next = <ProjectItem>[...project.items];
    final moved = next.removeAt(index);
    next.insert(target, moved);
    _writeItems(project, next);
  }

  /// 清空清单（**只清清单，不动正文**）。
  ///
  /// 给"拆错了想重来"用：拆完不满意时可以清掉再让 AI 拆一次。
  ///
  /// **清单本来就空时直接返回、不落盘**：这一条是刻意保留的 ——
  /// 原来门面里的实现有同样的守卫，去掉它会让"点一下清空"在空清单上
  /// 也写一次盘、白轮转一次备份。
  void clearProjectItems(String projectId) {
    final project = requireProject(projectId);
    if (project.items.isEmpty) return;
    _writeItems(project, const <ProjectItem>[]);
  }

  // ---------------------------------------------------------------- 与任务的唯一出口

  /// 把一条清单条目**建成任务**（Q24 的"规划 → 执行的桥"）。
  ///
  /// 落点交给调用方给的 `createTask` 回调：标题取条目文本、没有父节点，
  /// 于是排在事件主线的末尾。
  ///
  /// **只读清单、只调那一个回调**，不碰项目文档 —— 这是这一块对任务侧唯一的接触面，
  /// 与"清单不参与任何业务判定"那条边界一致。
  Task createTaskFromProjectItem({
    required String projectId,
    required String itemId,
    required String eventId,
    required Task Function({required String eventId, required String title}) createTask,
  }) {
    final project = requireProject(projectId);
    final item = project.items[itemIndex(project, itemId)];
    return createTask(eventId: eventId, title: item.text);
  }

  // ---------------------------------------------------------------- 内部

  /// 查到项目，查不到就抛。**原来叫 `Workspace._requireProject`** ——
  /// 门面里那个同名方法仍然留着（给事件/任务/重置用），两处都是三行。
  Project requireProject(String projectId) {
    final project = _findProject(projectId);
    if (project == null || project.deleted) throw const RuleViolation('项目不存在');
    return project;
  }

  /// 条目在数组里的下标；不存在就抛（**顺序就是下标**，见类文档）。
  int itemIndex(Project project, String itemId) {
    final index = project.items.indexWhere((i) => i.id == itemId);
    if (index < 0) throw const RuleViolation('条目不存在');
    return index;
  }

  /// 写下这一批条目（**整份替换项目的 `items`**，不是逐条改），然后落盘。
  ///
  /// `updatedAt` 由这里统一给：清单的每一次改动都算项目被改过。
  ///
  /// 落盘走 `WorkspaceState.persist()` —— **全层唯一的落盘出口**。
  /// 这里刻意不自己拼 `StoreFile`：那就是把"整份数据长什么样"在第二个地方
  /// 再写一遍，而这正是本次拆分要消灭的东西。
  void _writeItems(Project project, List<ProjectItem> items) {
    _state.upsert(
      DocName.projects,
      project.copyWith(items: items, updatedAt: Ids.nowMillis()),
    );
    _state.persist();
  }
}
