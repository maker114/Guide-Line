import '../../core/models/task.dart';
import '../../core/rules/completion.dart';

/// 哪些已完成的主线节点该**自动收起**。
///
/// 事件列表页与事件详情页共用这一条规则 —— 两处各写一份迟早会不一致：
/// 列表上看到的"当前节点"和点进去看到的不是同一个，那才是真的费解。
///
/// 规则（实机反馈）：任务线一长，做完的节点会把"现在做到哪"淹没。
/// 所以从**第一个未完成的主线节点**往回看，只保留它的**上一个**节点，
/// 再往前的已完成节点一律收起。
///
/// 为什么留一个而不是全收：完全没有上下文会让人不知道"这条线走到哪一步了"；
/// 留紧邻的那一个既省地方、又给了参照。
///
/// 全是终态（做完 / 搁置）就不折 —— 否则整条线会从界面上消失。
///
/// [userExpanded] 给"用户手动展开过"的节点一个豁免：显式选择优先于自动规则。
Set<String> autoFoldedMainLineIds(
  List<Task> mainLine, {
  bool Function(String taskId)? userExpanded,
}) {
  if (mainLine.isEmpty) return const <String>{};

  final frontier = mainLine.indexWhere((task) => !isTerminal(task.status));
  if (frontier < 0) return const <String>{};

  // 只留"当前节点的上一个"：上标 [0, frontier-1) 里的终态节点才是要收起的
  final folded = <String>{};
  for (var i = 0; i < frontier - 1; i += 1) {
    final task = mainLine[i];
    if (!isTerminal(task.status)) continue;
    if (userExpanded?.call(task.id) ?? false) continue;
    folded.add(task.id);
  }
  return folded;
}
