import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/events/event_detail_page.dart';

/// 任务行的入口与"被挡住"的表达（灵感 14 / 15）：
///   · 还有未处理子任务时，状态按钮换**锁形**，点它不改变状态、只解释原因；
///   · 子任务没勾完时，父任务不能被直接完成；
///   · 任务行上只留一个图标按钮「设到期日」，其余动作走点整行弹出的面板；
///   · Q27：动作面板能改归属（提到主线 / 挂到某个节点下），与"改归属"配套的
///     上下挪一格到两端时要给一句反馈。
///
/// 断言一律收在**任务线那一段**里（`eventDetailLineKey`）：详情页顶上那张卡
/// 还会用「接下来」把当前节点的标题再写一遍，也会画自己的日期图标 ——
/// 全屏数会数出两个。
void main() {
  late Directory tempDir;

  Finder inLine(Finder matching) => find.descendant(
        of: find.byKey(eventDetailLineKey),
        matching: matching,
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_lock_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> appWithTask({required bool withSubtask}) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '演示事件');
    final main = app.ws.createTask(eventId: event.id, title: '主线任务');
    if (withSubtask) {
      app.run(() => app.ws.createTask(
            eventId: event.id,
            title: '子任务甲',
            parentTaskId: main.id,
            type: TaskType.subtask,
          ));
    }
    return app;
  }

  Future<void> openEvent(WidgetTester tester, AppController app) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('演示事件'));
    await tester.pumpAndSettle();
  }

  testWidgets('有未处理子任务时，父任务的状态按钮是锁形', (tester) async {
    final app = await appWithTask(withSubtask: true);
    await openEvent(tester, app);

    expect(find.byIcon(Icons.lock_outline), findsOneWidget, reason: '父任务应显示锁形');
    // 子任务本身没有下级，仍是普通的状态按钮
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
  });

  testWidgets('点锁形不会改变状态，只给出原因', (tester) async {
    final app = await appWithTask(withSubtask: true);
    await openEvent(tester, app);

    await tester.tap(find.byIcon(Icons.lock_outline));
    await tester.pumpAndSettle();

    final main = app.ws.liveTasks.firstWhere((t) => t.parentId == null);
    expect(main.status, NodeStatus.pending, reason: '被挡住时不能变成已完成');
    expect(find.textContaining('还有子任务未处理'), findsOneWidget, reason: '要说清为什么做不了');
  });

  testWidgets('子任务勾完之后，父任务的锁消失、可以正常勾选', (tester) async {
    final app = await appWithTask(withSubtask: true);
    final subtask = app.ws.liveTasks.firstWhere((t) => t.parentId != null);
    app.run(() => app.ws.setTaskStatus(subtask.id, NodeStatus.done));

    await openEvent(tester, app);

    expect(find.byIcon(Icons.lock_outline), findsNothing, reason: '下级都处理完了就不该再锁着');
    await tester.tap(find.byIcon(Icons.radio_button_unchecked));
    await tester.pumpAndSettle();

    final main = app.ws.liveTasks.firstWhere((t) => t.parentId == null);
    expect(main.status, NodeStatus.done);
  });

  testWidgets('没有子任务的任务不显示锁形，可以直接完成', (tester) async {
    final app = await appWithTask(withSubtask: false);
    await openEvent(tester, app);

    expect(find.byIcon(Icons.lock_outline), findsNothing);
    await tester.tap(find.byIcon(Icons.radio_button_unchecked));
    await tester.pumpAndSettle();
    expect(app.ws.liveTasks.single.status, NodeStatus.done);
  });

  testWidgets('任务行上只留「设到期日」一个图标入口', (tester) async {
    final app = await appWithTask(withSubtask: false);
    await openEvent(tester, app);

    expect(inLine(find.byIcon(Icons.event_outlined)), findsOneWidget, reason: '没排期时是"设到期日"');
    // 「接后续任务…」那个折线入口跟着分叉 / 合流一起删了：链上不再有"走向"
    expect(inLine(find.byIcon(Icons.timeline)), findsNothing);

    // 设到期日：点开的是日期选择器（不再走"更多"菜单）
    await tester.tap(inLine(find.byIcon(Icons.event_outlined)));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
  });

  testWidgets('任务行尾那个到期日图标不贴边：离卡片右缘留出余量', (tester) async {
    final app = await appWithTask(withSubtask: false);
    await openEvent(tester, app);

    // 任务行那一整条（含它自己的内边距）与里面那颗日历图标的实际位置
    final tile = tester.getRect(inLine(find.byType(ListTile)).first);
    final icon = tester.getRect(inLine(find.byIcon(Icons.event_outlined)));

    expect(
      tile.right - icon.right,
      greaterThanOrEqualTo(12),
      reason: '行尾图标原本 contentPadding.right = 0，贴着行尾看着要掉出屏幕（实机反馈）',
    );
  });

  testWidgets('动作面板里只剩下"加一条 / 改这一条"的动作，没有走向类入口', (tester) async {
    final app = await appWithTask(withSubtask: true);
    await openEvent(tester, app);

    await tester.tap(inLine(find.text('主线任务')));
    await tester.pumpAndSettle();

    expect(find.text('新建子任务'), findsOneWidget);
    expect(find.text('往上挪一格'), findsOneWidget, reason: '链上节点可以调先后');
    expect(find.textContaining('接后续'), findsNothing);
    expect(find.textContaining('断开后续'), findsNothing);
    expect(find.textContaining('新建后续节点'), findsNothing);
  });

  testWidgets('设过到期日后图标换成"改到期日"，且任务行显示日期与剩余天数', (tester) async {
    final app = await appWithTask(withSubtask: false);
    final task = app.ws.liveTasks.single;
    app.run(() => app.ws.updateTask(task.id, dueAt: '2099-05-01'));

    await openEvent(tester, app);

    expect(inLine(find.byIcon(Icons.event_available_outlined)), findsOneWidget);
    expect(
      inLine(find.textContaining('2099-05-01')),
      findsOneWidget,
      reason: '任务行要同时给出绝对日期与剩余天数',
    );
  });

  testWidgets('改归属：子任务提到主线之后，它就是任务线上的节点（Q27）', (tester) async {
    final app = await appWithTask(withSubtask: true);
    final subtask = app.ws.liveTasks.firstWhere((t) => t.parentId != null);
    await openEvent(tester, app);

    // 子任务的行也在任务线里（父任务默认展开）
    await tester.tap(find.text('子任务甲'));
    await tester.pumpAndSettle();
    expect(find.text('改归属…'), findsOneWidget, reason: '数据层一直支持，缺的就是这个入口');

    await tester.tap(find.text('改归属…'));
    await tester.pumpAndSettle();
    expect(find.text('提到主线'), findsOneWidget);
    await tester.tap(find.text('提到主线'));
    await tester.pumpAndSettle();

    final moved = app.ws.findTask(subtask.id)!;
    expect(moved.parentId, isNull);
    expect(moved.taskType, TaskType.standard, reason: '提到主线必须写成 standard');
    expect(
      app.ws.mainLineOf(moved.eventId).map((t) => t.title),
      contains('子任务甲'),
      reason: '改完它就在主线上',
    );
  });

  testWidgets('改归属：挂到同一事件里另一个节点下（Q27）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '演示事件');
    final first = app.ws.createTask(eventId: event.id, title: '主线甲');
    final second = app.ws.createTask(eventId: event.id, title: '主线乙');
    final child = app.ws.createTask(
      eventId: event.id,
      title: '子任务甲',
      parentTaskId: first.id,
      type: TaskType.subtask,
    );

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('演示事件'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('子任务甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('改归属…'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('挂到「主线乙」下'));
    await tester.pumpAndSettle();

    final moved = app.ws.findTask(child.id)!;
    expect(moved.parentId, second.id);
    expect(moved.taskType, TaskType.subtask);
    expect(app.ws.subtasksOf(second.id, eventId: event.id).map((t) => t.id), <String>[child.id]);
    expect(app.ws.subtasksOf(first.id, eventId: event.id), isEmpty);
  });

  testWidgets('带下级的节点挂不到节点下：说清原因而不是点了才报错（Q27）', (tester) async {
    final app = await appWithTask(withSubtask: true);
    final parent = app.ws.liveTasks.firstWhere((t) => t.parentId == null);
    await openEvent(tester, app);

    await tester.tap(inLine(find.text('主线任务')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('改归属…'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('子任务不能再有下级'),
      findsOneWidget,
      reason: '挂下去它就成了叶子型子任务 —— 先把话说在门上',
    );
    expect(find.textContaining('挂到「'), findsNothing);
    // 什么都没动
    expect(app.ws.findTask(parent.id)!.parentId, isNull);
  });

  testWidgets('上下挪一格到两端：给一句反馈，不静默（Q27）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '演示事件');
    app.ws.createTask(eventId: event.id, title: '第一步');
    app.ws.createTask(eventId: event.id, title: '第二步');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('演示事件'));
    await tester.pumpAndSettle();

    // 第一个节点往上挪：到头了
    await tester.tap(inLine(find.text('第一步')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('往上挪一格'));
    await tester.pumpAndSettle();
    expect(find.text('已经是最前面了'), findsOneWidget);

    // 让上面那条轻提示先退场（`ScaffoldMessenger` 一次只显示一条，后面的要排队）
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // 最后一个节点往下挪：也到头了
    await tester.tap(inLine(find.text('第二步')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('往下挪一格'));
    await tester.pumpAndSettle();
    expect(find.text('已经到最后了'), findsOneWidget);

    // 顺序一动没动
    expect(
      app.ws.mainLineOf(event.id).map((t) => t.title),
      <String>['第一步', '第二步'],
    );
  });
}
