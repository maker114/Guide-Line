import '../models/enums.dart';
import '../models/inspiration.dart';
import '../models/project.dart';
import '../models/project_item.dart';

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
///
/// **不导出"相关事件与任务线"**（实机反馈）：事件与项目之间没有关联字段，
/// 全量带过去只会把这份说明撑得又长又跑题 —— 交接说明要回答的是"这个项目
/// 现在是什么状态"，不是"我所有的事都在做什么"。
class HandoffExport {
  const HandoffExport._();

  /// 生成整份 Markdown。
  static String build({
    required Project project,
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
        out.add('- ${_oneLine(inspiration.text)}');
      }
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

  // 完成 = 已完成；已搁置单独标出来（它不是"做完了"，但也不该让 AI 再提）
  static String _nodeStatus(NodeStatus status) {
    return switch (status) {
      NodeStatus.done => '已完成',
      NodeStatus.ignored => '已搁置',
      NodeStatus.pending => '进行中',
    };
  }

  /// 单行化：Markdown 是行结构，条目里混进换行会把列表拆散。
  static String _oneLine(String text) =>
      text.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');

  static String _stamp(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }
}
