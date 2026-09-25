import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';

/// 任务行的两个新入口与"被挡住"的表达（灵感 14 / 15）：
///   · 还有未处理子任务时，状态按钮换**锁形**，点它不改变状态、只解释原因；
///   · 子任务没勾完时，父任务不能被直接完成；
///   · 「设到期日」「接后续任务…」两个图标按钮直接落在任务行上。
void main() {
  late Directory tempDir;

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

  testWidgets('任务行上有「设到期日」与「接后续任务…」两个入口', (tester) async {
    final app = await appWithTask(withSubtask: false);
    await openEvent(tester, app);

    expect(find.byIcon(Icons.event_outlined), findsOneWidget, reason: '没排期时是"设到期日"');
    expect(find.byIcon(Icons.timeline), findsOneWidget, reason: '接后续任务的入口');

    // 设到期日：点开的是日期选择器（不再走"更多"菜单）
    await tester.tap(find.byIcon(Icons.event_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
  });

  testWidgets('设过到期日后图标换成"改到期日"，且任务行显示日期与剩余天数', (tester) async {
    final app = await appWithTask(withSubtask: false);
    final task = app.ws.liveTasks.single;
    app.run(() => app.ws.updateTask(task.id, dueAt: '2099-05-01'));

    await openEvent(tester, app);

    expect(find.byIcon(Icons.event_available_outlined), findsOneWidget);
    expect(
      find.textContaining('2099-05-01'),
      findsOneWidget,
      reason: '任务行要同时给出绝对日期与剩余天数',
    );
  });
}
