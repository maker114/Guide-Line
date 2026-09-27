import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/project_item.dart';
import 'package:guideline/core/rules/handoff_export.dart';

/// 交接说明（设计文档 §3）：给电脑上的 AI 读的 Markdown。
///
/// 格式是逻辑不是外观，所以在这里逐行钉住：任务列表语法、空节省略、
/// 已完成的也导、条目里的换行被单行化。
void main() {
  final now = DateTime(2026, 9, 25, 14, 30);

  Project project({
    String title = '示例项目',
    String purpose = '',
    String implementation = '',
    List<ProjectItem> items = const <ProjectItem>[],
    String? color,
    NodeStatus status = NodeStatus.pending,
    String? date,
  }) {
    return Project(
      id: 'p-1',
      title: title,
      purpose: purpose,
      implementation: implementation,
      date: date,
      status: status,
      archived: false,
      parentProjectId: null,
      order: 1000,
      completedAt: null,
      createdAt: 0,
      updatedAt: 0,
      deleted: false,
      color: color,
      items: items,
    );
  }

  Inspiration inspiration(
    String id,
    String text, {
    bool pending = true,
    List<String> tags = const <String>[],
    int createdAt = 0,
  }) {
    return Inspiration(
      id: id,
      text: text,
      projectId: 'p-1',
      status: pending ? InspirationStatus.pending : InspirationStatus.discarded,
      mergedInto: null,
      mergedAt: null,
      createdAt: createdAt,
      updatedAt: createdAt,
      deleted: false,
      tags: tags,
    );
  }

  /// `HandoffExport.build` **只接项目与灵感** —— 它的签名里根本没有事件 / 任务参数。
  ///
  /// 早先这个 helper 还收着 `events` / `tasks` 再用 `// ignore: unused_local_variable`
  /// 丢掉（T-1）：于是"交接说明里不出现事件与任务线"那几条 `isNot(contains(...))`
  /// **永远不可能失败**，看名字以为守住了，其实什么都没证明。
  /// 现在直接不接收它们 —— "事件与任务线进不了交接说明"是**编译期事实**，不是断言。
  String build({
    Project? p,
    List<Inspiration> inspirations = const <Inspiration>[],
  }) {
    return HandoffExport.build(
      project: p ?? project(),
      inspirations: inspirations,
      now: now,
    );
  }

  test('标题与元信息：只写有内容的项，且**不写项目状态**（Q1）', () {
    final text = build(
      p: project(
        title: '重构知识库',
        purpose: '让灵感不再散落',
        date: '2026-12-31',
        color: '#2f6feb',
        status: NodeStatus.done,
      ),
    );

    expect(text, startsWith('# 项目：重构知识库\n'));
    expect(text, contains('- 有什么问题 / 思路：让灵感不再散落'));
    expect(text, contains('- 日期：2026-12-31'));
    expect(text, contains('- 标识色：#2f6feb'));
    expect(text, contains('- 导出时间：2026-09-25 14:30'));
    // 项目没有完成 / 搁置（Q1）：老数据里的 done 也不再写进交接说明
    expect(text, isNot(contains('- 状态：')));
    expect(text, isNot(contains('已完成')));
    expect(text, isNot(contains('进行中')));
  });

  test('空的「有什么问题 / 思路」/ 日期 / 标识色不写出对应行', () {
    final text = build(p: project(title: '极简', purpose: '   '));
    expect(text, isNot(contains('- 有什么问题 / 思路：')));
    expect(text, isNot(contains('- 日期：')));
    expect(text, isNot(contains('- 标识色：')));
    expect(text, isNot(contains('- 状态：')));
  });

  test('清单用 GitHub 任务列表语法，已完成的打 x', () {
    final text = build(
      p: project(
        items: const <ProjectItem>[
          ProjectItem(id: 'i-1', text: '已完成的事', done: true),
          ProjectItem(id: 'i-2', text: '没做完的事', done: false),
        ],
      ),
    );

    expect(text, contains('## 实现清单'));
    expect(text, contains('- [x] 已完成的事'));
    expect(text, contains('- [ ] 没做完的事'));
  });

  test('空节整节省略，不留「（无）」', () {
    final text = build(p: project(title: '什么都没有'));
    expect(text, isNot(contains('## 实现清单')));
    expect(text, isNot(contains('## 如何解决')));
    expect(text, isNot(contains('## 待处理灵感')));
    expect(text, isNot(contains('## 相关事件与任务线')));
    expect(text.endsWith('\n'), isTrue);
  });

  test('「如何解决」正文原样带出（保留换行）', () {
    final text = build(p: project(implementation: '第一段\n\n第二段'));
    expect(text, contains('## 如何解决'));
    expect(text, contains('第一段\n\n第二段'));
  });

  test('灵感：只导 pending、倒序；已丢弃的不出现', () {
    final text = build(
      inspirations: <Inspiration>[
        inspiration('a', '较早的灵感', createdAt: 1000),
        inspiration('b', '较新的灵感', tags: <String>['工作', '生活'], createdAt: 2000),
        inspiration('c', '已经丢弃的灵感', pending: false, createdAt: 3000),
      ],
    );

    expect(text, contains('## 待处理灵感'));
    expect(text, isNot(contains('已经丢弃的灵感')));
    expect(
      text.indexOf('较新的灵感'),
      lessThan(text.indexOf('较早的灵感')),
      reason: '按创建时间倒序，与灵感页一致',
    );
    // 标签已从界面移除，导出里也不再带（老数据里的标签不再外发）
    expect(text, contains('- 较新的灵感'));
    expect(text, isNot(contains('工作 / 生活')));
  });

  test('交接说明不含事件与任务线 —— 这是接口层面的保证，不是运行时行为（T-1）', () {
    // 这份 helper 的签名里就没有 events / tasks（见顶部说明）：
    // "事件与任务线进不了交接说明"由 `HandoffExport.build` 的参数表决定，
    // 所以这里能验的只有"项目自己的内容照常写出来"，
    // 以及"说明里不含那几个只可能来自事件 / 任务线的词"。
    final text = build(p: project(title: '重构知识库'));

    expect(text, contains('# 项目：重构知识库'));
    expect(text, isNot(contains('相关事件与任务线')));
    // 这些词只可能来自事件名或任务标题：确认正文里没有夹带
    for (final word in <String>['上线准备', '搬家', '第一条主线', '子任务']) {
      expect(text, isNot(contains(word)), reason: '「$word」不该出现在交接说明里');
    }
  });

  test('条目里的换行被单行化（否则会把 Markdown 列表拆散）', () {
    final text = build(
      p: project(
        items: const <ProjectItem>[
          ProjectItem(id: 'i-1', text: '第一行\n第二行', done: false),
        ],
      ),
    );
    expect(text, contains('- [ ] 第一行 第二行'));
    expect(text, isNot(contains('第一行\n第二行')));
  });
}
