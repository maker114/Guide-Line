import '../models/enums.dart';
import '../models/event.dart';
import '../models/inspiration.dart';
import '../models/project.dart';
import '../models/project_item.dart';
import '../models/task.dart';

/// 把项目生成一份**交接说明**（Markdown），用来导出到电脑上丢给 AI
/// （设计文档 §3）。
///
/// 纯 Dart、无 Flutter 依赖：格式是逻辑，不是外观，所以放 core 并能被单测覆盖。
///
/// 三条格式决定，都是为了让对面那个 AI 好读：
///   · 任务列表用 **`- [x]` / `- [ ]`**（GitHub 任务列表语法）—— 最容易被读懂，
///     粘进 issue 也能直接用；
///   · **已完成的也导**（打 `[x]`）—— AI 得知道"已经做了什么"才不会重复建议；
///   · **空节整节省略**，不留一堆 `（无）`。
class HandoffExport {
  const HandoffExport._();

  /// 生成整份 Markdown。
  ///
  /// [events] 与 [tasks] 传**全部**事件与任务（不是只属于这个项目的）：
  /// 事件与项目之间**没有关联字段**（事件属于项目需要改数据契约，不在本版范围），
  /// 所以"与该项目相关的事件"无从判断。交接说明的用途是"把当前状态讲清楚"，
  /// 多带一点上下文比漏掉更有用，因此全带并把事件名写清楚。
  static String build({
    required Project project,
    required List<Event> events,
    required List<Task> tasks,
    required List<Inspiration> inspirations,
    required DateTime now,
  }) {
    final out = <String>[];

    out.add('# 项目：${project.title.trim()}');
    out.add('');
    final meta = <String>[];
    if (project.purpose.trim().isNotEmpty) meta.add('- 目的：${project.purpose.trim()}');
    if (project.date != null) meta.add('- 日期：${project.date}');
    meta.add('- 状态：${_nodeStatus(project.status)}');
    if (project.color != null) meta.add('- 标识色：${project.color}');
    meta.add('- 导出时间：${_stamp(now)}');
    out.addAll(meta);

    final checklist = _checklistSection(project.items);
    if (checklist.isNotEmpty) {
      out.add('');
      out.addAll(checklist);
    }

    final body = project.implementation.trim();
    if (body.isNotEmpty) {
      out.add('');
      out.add('## 实现说明');
      out.add('');
      out.add(body);
    }

    final pending = inspirations.where((i) => i.isPending && !i.deleted).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (pending.isNotEmpty) {
      out.add('');
      out.add('## 待处理灵感');
      out.add('');
      for (final inspiration in pending) {
        final tags = inspiration.tags.isEmpty ? '' : '（${inspiration.tags.join(' / ')}）';
        out.add('- ${_oneLine(inspiration.text)}$tags');
      }
    }

    final eventSection = _eventsSection(events, tasks);
    if (eventSection.isNotEmpty) {
      out.add('');
      out.addAll(eventSection);
    }

    return '${out.join('\n')}\n';
  }

  // 清单：`- [x] 文本`
  static List<String> _checklistSection(List<ProjectItem> items) {
    if (items.isEmpty) return const <String>[];
    return <String>[
      '## 实现清单',
      '',
      for (final item in items) '- [${item.done ? 'x' : ' '}] ${_oneLine(item.text)}',
    ];
  }

  // 事件与任务线：任务是 `- [x]`，框内的子任务缩进一层
  static List<String> _eventsSection(List<Event> events, List<Task> tasks) {
    final sorted = [...events]..sort((a, b) => a.order.compareTo(b.order));
    final lines = <String>[];

    for (final event in sorted) {
      final own = tasks.where((t) => t.eventId == event.id && !t.deleted).toList();
      if (own.isEmpty) continue;

      if (lines.isNotEmpty) lines.add('');
      lines.add('### ${_oneLine(event.name)}');

      // 主线：`parent_task_id == null`，按 order；子任务挂在各自父任务下面
      for (final task in _roots(own)) {
        lines.add(_taskLine(task, 0));
        for (final child in _childrenOf(own, task.id)) {
          lines.add(_taskLine(child, 1));
        }
      }
    }
    return lines.isEmpty ? const <String>[] : <String>['## 相关事件与任务线', '', ...lines];
  }

  static List<Task> _roots(List<Task> tasks) {
    final roots = tasks.where((t) => t.parentId == null).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return roots;
  }

  static List<Task> _childrenOf(List<Task> tasks, String parentId) {
    final children = tasks.where((t) => t.parentId == parentId).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return children;
  }

  static String _taskLine(Task task, int indent) {
    final pad = '    ' * indent;
    final marker = task.status == NodeStatus.done ? 'x' : ' ';
    // 任务类型只在"主线 / 框内"这一层有意义（导出里靠缩进就能看出来）：
    // `parallel` 是历史类型（见 [TaskType]），按子任务一样处理，不再单独标注
    final kind = task.taskType == TaskType.standard ? '' : '（子任务）';
    final due = task.dueAt == null ? '' : ' — 截止 ${task.dueAt}';
    return '$pad- [$marker] ${_oneLine(task.title)}$kind$due';
  }

  // 完成 = 已完成；已搁置单独标出来（它不是"做完了"，但也不该让 AI 再提）
  static String _nodeStatus(NodeStatus status) {
    return switch (status) {
      NodeStatus.done => '已完成',
      NodeStatus.ignored => '已搁置',
      NodeStatus.pending => '进行中',
    };
  }

  /// 单行化：Markdown 是行结构，条目里混进换行会把列表拆散。
  static String _oneLine(String text) => text.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');

  static String _stamp(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }
}
