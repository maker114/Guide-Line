import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/event.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/project_item.dart';
import 'package:guideline/core/models/task.dart';
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

  Task task(
    String id, {
    required String eventId,
    required String title,
    String? parentId,
    TaskType type = TaskType.standard,
    NodeStatus status = NodeStatus.pending,
    int order = 1000,
    String? dueAt,
  }) {
    return Task(
      id: id,
      eventId: eventId,
      parentTaskId: parentId,
      nextIds: const <String>[],
      taskType: type,
      title: title,
      dueAt: dueAt,
      status: status,
      archived: false,
      order: order,
      completedAt: null,
      createdAt: 0,
      updatedAt: 0,
      deleted: false,
    );
  }

  Event event(String id, String name, {int order = 1000}) => Event(
        id: id,
        name: name,
        status: NodeStatus.pending,
        archived: false,
        order: order,
        completedAt: null,
        createdAt: 0,
        updatedAt: 0,
        deleted: false,
      );

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

  String build({
    Project? p,
    List<Event> events = const <Event>[],
    List<Task> tasks = const <Task>[],
    List<Inspiration> inspirations = const <Inspiration>[],
  }) {
    return HandoffExport.build(
      project: p ?? project(),
      events: events,
      tasks: tasks,
      inspirations: inspirations,
      now: now,
    );
  }

  test('标题与元信息：只写有内容的项，状态译成中文', () {
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
    expect(text, contains('- 目的：让灵感不再散落'));
    expect(text, contains('- 日期：2026-12-31'));
    expect(text, contains('- 状态：已完成'));
    expect(text, contains('- 标识色：#2f6feb'));
    expect(text, contains('- 导出时间：2026-09-25 14:30'));
  });

  test('空的目的 / 日期 / 标识色不写出对应行', () {
    final text = build(p: project(title: '极简', purpose: '   '));
    expect(text, isNot(contains('- 目的：')));
    expect(text, isNot(contains('- 日期：')));
    expect(text, isNot(contains('- 标识色：')));
    expect(text, contains('- 状态：进行中'));
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
    expect(text, isNot(contains('## 实现说明')));
    expect(text, isNot(contains('## 待处理灵感')));
    expect(text, isNot(contains('## 相关事件与任务线')));
    expect(text.endsWith('\n'), isTrue);
  });

  test('实现说明原样带出（保留换行）', () {
    final text = build(p: project(implementation: '第一段\n\n第二段'));
    expect(text, contains('## 实现说明'));
    expect(text, contains('第一段\n\n第二段'));
  });

  test('灵感：只导 pending、倒序、带标签；已丢弃的不出现', () {
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
    expect(text, contains('- 较新的灵感（工作 / 生活）'));
  });

  test('事件与任务线：主线在前、子任务缩进一层、已完成的打 x', () {
    final text = build(
      events: <Event>[event('e-1', '上线准备')],
      tasks: <Task>[
        task('t-2', eventId: 'e-1', title: '第二条主线', order: 2000),
        task('t-1', eventId: 'e-1', title: '第一条主线', order: 1000, status: NodeStatus.done),
        task('t-1a', eventId: 'e-1', title: '子任务', parentId: 't-1', type: TaskType.subtask),
      ],
    );

    expect(text, contains('## 相关事件与任务线'));
    expect(text, contains('### 上线准备'));
    expect(text, contains('- [x] 第一条主线'));
    expect(text, contains('- [ ] 第二条主线'));
    expect(text, contains('    - [ ] 子任务（子任务）'));
    expect(
      text.indexOf('第一条主线'),
      lessThan(text.indexOf('第二条主线')),
      reason: '主线按 order 排',
    );
  });

  test('历史的并列任务按子任务标注（类型已废除），截止日跟在后面', () {
    final text = build(
      events: <Event>[event('e-1', '出行')],
      tasks: <Task>[
        task(
          't-1',
          eventId: 'e-1',
          title: '并列的那条',
          type: TaskType.parallel,
          dueAt: '2026-10-01',
        ),
      ],
    );
    // 导出是给对面那个 AI 看的：`parallel` 已经没有对应概念，
    // 按"框内的下级"标注即可，不再出现「并列」这种它读不懂的旧类型名
    expect(text, contains('- [ ] 并列的那条（子任务） — 截止 2026-10-01'));
    expect(text, isNot(contains('（并列）')));
  });

  test('没有任务的事件不产生空小节', () {
    final text = build(
      events: <Event>[event('e-1', '空事件'), event('e-2', '有任务')],
      tasks: <Task>[task('t-1', eventId: 'e-2', title: '一条任务')],
    );
    expect(text, isNot(contains('空事件')));
    expect(text, contains('### 有任务'));
  });

  test('任务或条目里的换行被单行化（否则会把 Markdown 列表拆散）', () {
    final text = build(
      p: project(
        items: const <ProjectItem>[
          ProjectItem(id: 'i-1', text: '第一行\n第二行', done: false),
        ],
      ),
      events: <Event>[event('e-1', '事件')],
      tasks: <Task>[task('t-1', eventId: 'e-1', title: '标题\n带换行')],
    );
    expect(text, contains('- [ ] 第一行 第二行'));
    expect(text, contains('- [ ] 标题 带换行'));
    expect(text, isNot(contains('第一行\n第二行')));
  });
}
