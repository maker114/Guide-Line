import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/rules/cascade.dart';
import 'package:guideline/ui/events/task_actions.dart';

/// **事件删除确认框**：全应用只有一份文案、只有一个条数算法。
///
/// 两份实现在 2026-10-01 合并之前的形状是：标题、两种文案、确认词、`danger`
/// **逐字相同**，而**任务数各算一遍** —— 事件列表调 `eventDeletionTaskIds`
/// （cascade 的规格实现），事件详情页内联
/// `allTasks.where(eventId 匹配 && !deleted)`。
///
/// 两者**当时恰好等价**，所以这不是"已发生的分歧"，而是**等爆耦合**：
/// cascade 一改，两个入口就会报出不同条数 —— 而用户正是照那个数决定删不删。
///
/// 这个文件守两件事：① 两种文案分支都对（有任务 / 没任务）；
/// ② 那个条数**就是这个函数算出来的**（与 `eventDeletionTaskIds` 同源）。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guideline_delete_event_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 把确认框挂在一个按钮上，点它才弹（`confirmDeleteEvent` 是它的产物）。
  ///
  /// [capture] 用来**接住返回值** —— 有两条用例的标题写的就是"返回 true/false"，
  /// 而它们原来只断言"事件还在"，**从没看过返回值**（独立核验指出）。
  /// 一个测试的标题若声称验了某件事，那件事就必须真的被断言。
  Future<void> openDialog(
    WidgetTester tester,
    AppController app,
    String eventId, {
    void Function(bool)? capture,
  }) async {
    final event = app.ws.findEvent(eventId)!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final ok = await confirmDeleteEvent(context, app, event);
                capture?.call(ok);
              },
              child: const Text('问一句'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('问一句'));
    await tester.pumpAndSettle();
  }

  testWidgets('没有任务时：只说"可在回收站恢复"，不编造条数', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '空事件');

    await openDialog(tester, app, event.id);

    expect(find.text('删除事件'), findsOneWidget, reason: '标题');
    expect(
      find.textContaining('删除「空事件」。可在「更多 → 归档区 → 回收站」恢复。'),
      findsOneWidget,
      reason: '一条任务都没有时说"共 0 个任务会被删除"是废话',
    );
    expect(find.textContaining('整条任务线共'), findsNothing);
  });

  testWidgets('有任务时：条数与 `eventDeletionTaskIds` 同源（含子任务）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一件事');
    final node = app.ws.createTask(eventId: event.id, title: '主线节点');
    // 子任务必须指定类型：`standard` 主线节点**挂不了 `standard` 子任务**
    // （`Task.canHaveChild` 的硬规则，`workspace.dart` 的 createTask 会抛）。
    app.ws.createTask(
      eventId: event.id,
      title: '子任务一',
      parentTaskId: node.id,
      type: TaskType.subtask,
    );
    app.ws.createTask(
      eventId: event.id,
      title: '子任务二',
      parentTaskId: node.id,
      type: TaskType.subtask,
    );

    // 另一条事件的任务不该被算进来
    final other = app.ws.createEvent(name: '另一件事');
    app.ws.createTask(eventId: other.id, title: '别人家的任务');

    // 规格实现的答案（界面必须与它一致）
    final expected = eventDeletionTaskIds(app.ws.allTasks, event.id).length;
    expect(expected, 3, reason: '节点 + 两条子任务；另一条事件的不算');

    await openDialog(tester, app, event.id);

    expect(
      find.textContaining('「一件事」及其整条任务线共 $expected 个任务会被一起删除'),
      findsOneWidget,
      reason: '这个数必须来自 `eventDeletionTaskIds` —— '
          '详情页原来内联另算一遍（当时恰好等价），那是等爆耦合',
    );
  });

  testWidgets('已软删的任务不计入条数（与规格实现同一判据）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一件事');
    final keep = app.ws.createTask(eventId: event.id, title: '留下的');
    final gone = app.ws.createTask(eventId: event.id, title: '已删掉的');
    app.run(() => app.ws.deleteTask(gone.id));

    final expected = eventDeletionTaskIds(app.ws.allTasks, event.id).length;
    expect(expected, 1, reason: '软删的那条不再算数（规格实现就是 `!deleted`）');
    expect(keep.deleted, isFalse);

    await openDialog(tester, app, event.id);
    expect(
      find.textContaining('共 $expected 个任务'),
      findsOneWidget,
      reason: '内联那版也带 `!deleted`，所以这两处**当时等价** —— '
          '这条用例的价值是：以后哪一版改了判据，这里会红',
    );
  });

  testWidgets('取消：返回 false，不删任何东西', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一件事');

    bool? returned;
    await openDialog(tester, app, event.id, capture: (ok) => returned = ok);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(
      returned,
      isFalse,
      reason: '标题说"返回 false"，就必须真的断言那个返回值 —— '
          '原来只断言"事件还在"，而那是**另一件事**（它证明的是"函数没自己删"）',
    );
    expect(
      app.ws.findEvent(event.id),
      isNotNull,
      reason: '`confirmDeleteEvent` 只问不删 —— 删的动作归调用方',
    );
    expect(app.ws.findEvent(event.id)!.deleted, isFalse);
  });

  testWidgets('确认：返回 true（调用方据此去删）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一件事');
    expect(event.status, NodeStatus.pending);

    bool? returned;
    await openDialog(tester, app, event.id, capture: (ok) => returned = ok);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(
      returned,
      isTrue,
      reason: '确认之后必须返回 true，调用方才有依据去删 —— '
          '原来只断言"事件还在"，那对 true/false 两种实现都成立',
    );
    // 这个函数自己不删 —— 所以事件还在
    expect(app.ws.findEvent(event.id)!.deleted, isFalse);
  });
}
