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
///
/// **不导出项目状态**（Q1）：项目没有完成 / 搁置，只有"要 / 不要"；
/// `status` / `completed_at` 只是老数据里只读保留的字段，写进交接说明只会误导
/// 对面的 AI（"已完成"其实不代表这个项目不做了）。不做了就该归档。
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
    // 字段名与界面同步（Q4）：「目的」→「有什么问题 / 思路」
    if (project.purpose.trim().isNotEmpty) {
      meta.add('- 有什么问题 / 思路：${project.purpose.trim()}');
    }
    if (project.date != null) meta.add('- 日期：${project.date}');
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
      // 与界面字段名一致（Q4）：「实现计划」→「如何解决」
      out.add('## 如何解决');
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

  /// 单行化：Markdown 是行结构，条目里混进换行会把列表拆散。
  static String _oneLine(String text) =>
      text.trim().replaceAll(RegExp(r'\s*\n\s*'), ' ');

  static String _stamp(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }
}
