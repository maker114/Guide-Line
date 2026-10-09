import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/inline_editor.dart';
import 'package:guideline/ui/events/event_detail_page.dart';
import 'package:guideline/ui/more/all_tasks_page.dart';

/// 任务**待办清单**的界面接线（《数据契约》§3.4.2）。
///
/// 这一份测"点得到吗、看得到吗、勾了之后数据对不对"，不测判定规则
/// （那是 `test/core/workspace_task_checklist_test.dart` 的事）。
///
/// 两处落点都要覆盖，因为它们共用同一份数据但渲染在完全不同的容器里：
///   · **事件详情页** —— 任务框里、子任务上方，靠缩进 + 浅底表示层级；
///   · **任务行**（「全部任务」「接下来的任务」「日历」「搜索」共用）
///     —— 就地展开、就地勾，用户不必进事件详情。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_task_checklist_ui_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() =>
      AppController.bootstrap(dataDirectoryOverride: tempDir);

  /// 待办行的 key（`taskChecklistRowKeyPrefix + 条目 id`）。
  Finder rowKey(String itemId) =>
      find.byKey(ValueKey<String>('$taskChecklistRowKeyPrefix$itemId'));

  /// 打开事件详情页（照 `task_row_actions_test` 那条路径：外壳 → 事件 → 卡片）。
  Future<void> openEvent(WidgetTester tester, AppController app, String name) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  /// 点某一行待办的**圆形勾选**（不是点整行：列表页里点整行也是勾，
  /// 详情页里点文字是改名 —— 两种落点都要按得到）。
  Future<void> tapCircle(WidgetTester tester, String itemId) async {
    final circle = find.descendant(
      of: rowKey(itemId),
      matching: find.byIcon(Icons.radio_button_unchecked),
    );
    final checked = find.descendant(
      of: rowKey(itemId),
      matching: find.byIcon(Icons.check_circle),
    );
    await tester.tap(circle.evaluate().isNotEmpty ? circle : checked);
    await tester.pumpAndSettle();
  }

  group('事件详情页', () {
    testWidgets('待办排在任务与它的下级之间，用缩进表示层级、没有从属符', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');
      app.run(() => app.ws.createTask(
            eventId: event.id,
            title: '子任务甲',
            parentTaskId: task.id,
            type: TaskType.subtask,
          ));

      await openEvent(tester, app, '演示事件');

      // 三行的纵向次序：任务行 → 待办行 → 子任务行
      final taskRow = tester.getRect(find.text('写解析层'));
      final checklistRow = tester.getRect(rowKey(item.id));
      final childRow = tester.getRect(find.text('子任务甲'));
      expect(checklistRow.top, greaterThan(taskRow.bottom), reason: '待办在任务行下方');
      expect(checklistRow.bottom, lessThan(childRow.top), reason: '待办排在下级之前');

      // 真缩进：待办那一行的**文字**比子任务行的文字更靠右（两者字号相同，
      // 所以左缘可比）。待办行刻意比子任务多缩进一档 —— 层级只靠缩进表示。
      final checklistText = tester.getRect(
        find.descendant(of: rowKey(item.id), matching: find.text('先写契约')),
      );
      expect(checklistText.left, greaterThan(childRow.left),
          reason: '待办文字（${checklistText.left}）应当比子任务文字（${childRow.left}）更靠右');

      // **没有从属符**：子任务那套"短竖线 + 从属箭头"不出现在待办行里
      expect(
        find.descendant(
          of: rowKey(item.id),
          matching: find.byIcon(Icons.subdirectory_arrow_right),
        ),
        findsNothing,
        reason: '待办只用缩进区分，不画从属符',
      );
    });

    testWidgets('就地录入：任务框里常驻一行「加一条待办」，点开就能写', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');

      await openEvent(tester, app, '演示事件');

      // 一条待办都没有的新任务，也必须能看到这个入口 ——
      // 否则第一条细则根本没地方加（默认收起的坑就是这条用例抓出来的）
      expect(find.text('加一条待办'), findsOneWidget);

      await tester.tap(find.text('加一条待办'));
      await tester.pumpAndSettle();
      final focused = find.byWidgetPredicate(
        (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
        description: '当前获得焦点的输入框',
      );
      expect(focused, findsOneWidget, reason: '点它就展开一个输入框，不经过任务动作面板');

      await tester.enterText(focused, '先写契约');
      final composer = find.ancestor(of: focused, matching: find.byType(InlineComposer));
      await tester.tap(find.descendant(of: composer, matching: find.byTooltip('添加')));
      await tester.pumpAndSettle();

      expect(app.ws.taskChecklistOf(task.id).map((i) => i.text), <String>['先写契约']);
      expect(find.text('待办 0/1'), findsOneWidget, reason: '摘要跟着出来');
    });

    testWidgets('勾一条待办：只改它自己 —— 任务状态与子任务一律不动', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');
      final child = app.ws.createTask(
        eventId: event.id,
        title: '子任务甲',
        parentTaskId: task.id,
        type: TaskType.subtask,
      );

      await openEvent(tester, app, '演示事件');
      await tapCircle(tester, item.id);

      expect(app.ws.taskChecklistOf(task.id).single.done, isTrue, reason: '待办真的勾上了');
      expect(app.ws.findTask(task.id)!.status, NodeStatus.pending, reason: '任务状态不许跟着变');
      expect(app.ws.findTask(child.id)!.status, NodeStatus.pending);
      expect(find.text('待办 1/1'), findsOneWidget, reason: '摘要跟着走');
    });

    testWidgets('默认展开规则：有未勾完的展开；展开后切到「收起」再点就收起来', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');

      await openEvent(tester, app, '演示事件');
      expect(find.text('待办 0/1'), findsOneWidget);
      expect(rowKey(item.id), findsOneWidget, reason: '有未勾完的待办 ⇒ 默认展开');

      // 点摘要那一行收起
      await tester.tap(find.text('待办 0/1'));
      await tester.pumpAndSettle();
      expect(rowKey(item.id), findsNothing, reason: '收起后不画条目行');
      expect(find.text('待办 0/1'), findsOneWidget, reason: '收起时留一行摘要');

      // 再点开回来
      await tester.tap(find.text('待办 0/1'));
      await tester.pumpAndSettle();
      expect(rowKey(item.id), findsOneWidget);
    });

    testWidgets('勾完的待办划掉；摘要照写 d/t，任务仍要手动标记完成', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');

      // 先用数据把它勾上，**再**打开页面。全勾完之后按默认规则是**收起**的
      // （摘要还在，条目行不画）—— 这也顺手把"收起时留摘要"那一条验了。
      app.run(() => app.ws.setTaskChecklistItemDone(task.id, item.id, true));
      await openEvent(tester, app, '演示事件');

      expect(find.text('待办 1/1'), findsOneWidget);
      expect(rowKey(item.id), findsNothing, reason: '全勾完 ⇒ 默认收成一行摘要');

      // 点摘要展开，看勾完的条目长什么样
      await tester.tap(find.text('待办 1/1'));
      await tester.pumpAndSettle();
      expect(rowKey(item.id), findsOneWidget);

      final text = tester.widget<Text>(
        find.descendant(of: rowKey(item.id), matching: find.byType(Text)),
      );
      expect(text.style?.decoration, TextDecoration.lineThrough, reason: '勾完的条目要划掉');
      expect(
        find.descendant(
          of: rowKey(item.id),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
        reason: '圆形勾选要变成实心对勾',
      );
      expect(app.ws.findTask(task.id)!.status, NodeStatus.pending,
          reason: '待办全勾完也不许自动完成任务');

      // 再点一次把它取消：两态要能来回
      await tapCircle(tester, item.id);
      expect(app.ws.taskChecklistOf(task.id).single.done, isFalse);
      expect(app.ws.findTask(task.id)!.status, NodeStatus.pending);
      expect(find.text('待办 0/1'), findsOneWidget);
    });
  });

  group('任务行（全部任务 / 接下来的任务 / 日历共用）', () {
    Future<AppController> bootWithChecklist({int items = 2}) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      for (var i = 0; i < items; i += 1) {
        app.ws.addTaskChecklistItem(task.id, '细则 ${i + 1}');
      }
      return app;
    }

    Future<void> openAllTasks(WidgetTester tester, AppController app) async {
      await tester.pumpWidget(MaterialApp(home: AllTasksPage(app: app)));
      await tester.pumpAndSettle();
    }

    testWidgets('摘要与展开箭头上行；展开后能就地勾，且**不跳进事件详情**', (tester) async {
      final app = await bootWithChecklist();
      final task = app.ws.findTask(app.ws.liveTasks.single.id)!;
      final items = app.ws.taskChecklistOf(task.id);

      await openAllTasks(tester, app);
      expect(find.text('待办 0/2'), findsOneWidget, reason: '任务行副标题带摘要');

      // 有未勾完的待办 ⇒ 默认展开，所以这里是「收起」；先收起再展开，两个方向都走一遍
      await tester.tap(find.byTooltip('收起待办'));
      await tester.pumpAndSettle();
      expect(rowKey(items.first.id), findsNothing, reason: '收起后不画条目行');

      await tester.tap(find.byTooltip('展开待办'));
      await tester.pumpAndSettle();
      expect(rowKey(items.first.id), findsOneWidget, reason: '展开区里画出条目');

      // 点整行 = 勾选，**不跳转**（跳了的话这一页就没了）
      await tester.tap(rowKey(items.first.id));
      await tester.pumpAndSettle();

      expect(app.ws.taskChecklistOf(task.id).first.done, isTrue);
      expect(find.byType(AllTasksPage), findsOneWidget, reason: '勾待办不该离开这一页');
      expect(find.byType(EventDetailPage), findsNothing);
      expect(find.text('待办 1/2'), findsOneWidget, reason: '摘要即时更新');
    });

    testWidgets('点标题仍然进事件详情（展开箭头不吃掉整行的点击）', (tester) async {
      final app = await bootWithChecklist();
      await openAllTasks(tester, app);

      await tester.tap(find.text('写解析层'));
      await tester.pumpAndSettle();

      expect(find.byType(EventDetailPage), findsOneWidget);
    });

    testWidgets('没有待办的任务行：不给箭头（点了没反应的箭头比没有更烦人）', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      app.ws.createTask(eventId: event.id, title: '没有细则的任务');

      await openAllTasks(tester, app);

      expect(find.byTooltip('展开待办'), findsNothing);
      expect(find.textContaining('待办 '), findsNothing);
    });

    testWidgets('多选态下勾不到待办（那一行整行只认"选中"）', (tester) async {
      final app = await bootWithChecklist();
      final task = app.ws.findTask(app.ws.liveTasks.single.id)!;
      final items = app.ws.taskChecklistOf(task.id);

      await openAllTasks(tester, app);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选'), findsOneWidget, reason: '确实进了多选态');

      // 多选态下整行被 `AbsorbPointer` 挡住，点哪儿都不会勾到待办
      // （`TaskTile` 的展开钮与展开区里的勾选一起失效）。
      // 用 `tapAt` 而不是 `tap`：`tap` 会先做命中检查，被挡住时直接报
      // "找不到可点的控件"，那就没验到"点了没反应"这件事。
      final rect = tester.getRect(find.text('写解析层'));
      await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();

      expect(app.ws.taskChecklistOf(task.id).first.done, isFalse, reason: '一条都不该被勾上');
      // 展开状态也一个字没动：有待办的默认就是展开，点它**不该**被收起
      // （点得动的话，第一下就会把清单收走 —— 那是最容易被忽略的一种"误触"）。
      expect(
        app.isExpanded('checklist-${task.id}', defaultExpanded: true),
        isTrue,
        reason: '多选态下的点击不该改动待办的展开状态',
      );
      expect(rowKey(items.first.id), findsOneWidget);
    });
  });
}
