import '../../core/models/enums.dart';
import '../../core/models/task.dart';

/// 一条事件线上"最该回答的两个问题"：**急不急**（最近到期）与**下一步做哪件**（接下来）。
///
/// 这两个答案原来只长在事件列表的卡头上（一行小灰字「最近 … · 接下来 · …」）。
/// 实机反馈要求卡头别塞这句，而把这两件事**挪进事件详情页**放大显示 ——
/// 于是取数搬到这个文件里，详情页直接调，列表页不再自己算一套。
///
/// 为什么值得单独一个文件：这条规则里藏着好几个"看起来对但其实错"的写法 ——
///   · 最近到期**只数未终结的节点**（已完成 / 已搁置的任务不再催人）；
///   · 日期是**字符串比大小**：全应用只收 `YYYY-MM-DD`，字典序就是时间序
///     （换成 `DateTime` 反而要处理解析失败与本地时区，得不偿失）；
///   · "接下来"是**第一个还没终结的节点**：任务线的顺序本身就是"接着做"的顺序
///     （《定义与边界》§2.3）。
/// 所以它做成纯函数、单独有测试（`test/ui/event_tab_test.dart` 里那一组）。
class NextUp {
  const NextUp({required this.dueAt, required this.task});

  /// 还没终结的主线节点里最近的那个到期日；一个都没排期时是 `null`。
  final String? dueAt;

  /// 第一个还没终结的主线节点（"接下来做这一件"）；线上没有未终结节点时是 `null`。
  final Task? task;
}

/// 按主线任务取"最近到期 + 接下来做什么"。
///
/// [mainLine] 请传 `Workspace.mainLineOf(eventId)` 的结果 ——
/// 它已经排好序、也排除了已归档的节点（Q18：显示与判定同一套取数）。
NextUp nextUpOf(List<Task> mainLine) {
  // 未终结 = `pending`：`done` 与 `ignored` 都是"不用再管了"
  // （与 `task_fold.dart` 的自动收起、事件详情页的当前节点是同一个判据）。
  final open = mainLine.where((t) => t.status == NodeStatus.pending);

  String? dueAt;
  for (final task in open) {
    final due = task.dueAt;
    if (due == null || due.isEmpty) continue;
    if (dueAt == null || due.compareTo(dueAt) < 0) dueAt = due;
  }

  return NextUp(
    dueAt: dueAt,
    task: mainLine.where((t) => t.status == NodeStatus.pending).firstOrNull,
  );
}
