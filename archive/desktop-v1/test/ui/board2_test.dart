import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/main.dart';

/// 板块二（事件与任务线）渲染测试：验证设计文档 4.9 的三条呈现规则。
void main() {
  late Directory dir;
  late AppController app;
  late String eventId;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_board2_');
    app = AppController.bootstrap(dataDirectoryOverride: dir);
    eventId = app.ws.createEvent(name: '把知识库做出来').id;
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> openBoard2(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(GuidelineApp(controller: app));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件与任务线'));
    await tester.pumpAndSettle();
  }

  testWidgets('主线：标准任务纵向串联，并显示连线与序号', (tester) async {
    app.ws.createTask(eventId: eventId, title: '写数据契约');
    app.ws.createTask(eventId: eventId, title: '实现同步层');

    await openBoard2(tester);

    expect(find.text('1. 写数据契约'), findsOneWidget);
    expect(find.text('2. 实现同步层'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down), findsWidgets, reason: '主线用连线表达次序');
  });

  testWidgets('子任务渲染在父框内（缩进 + └ 前缀），并列任务是独立框', (tester) async {
    final standard = app.ws.createTask(eventId: eventId, title: '实现同步层');
    app.ws.createTask(
      eventId: eventId,
      title: '写 commitTx',
      parentTaskId: standard.id,
      type: TaskType.subtask,
    );
    final parallel = app.ws.createTask(
      eventId: eventId,
      title: '两条路都可行',
      parentTaskId: standard.id,
      type: TaskType.parallel,
    );
    app.ws.createTask(
      eventId: eventId,
      title: '并列下的子任务',
      parentTaskId: parallel.id,
      type: TaskType.subtask,
    );

    await openBoard2(tester);

    expect(find.text('写 commitTx'), findsOneWidget);
    expect(find.text('└'), findsWidgets, reason: '子任务缩进在父框内');
    expect(find.textContaining('并列任务（分叉，互不依赖）'), findsOneWidget);
    expect(find.text('⑂ 两条路都可行'), findsOneWidget, reason: '并列任务是独立框');
    expect(find.text('并列下的子任务'), findsOneWidget, reason: '并列任务的子任务仍在它自己的框内');
  });

  testWidgets('事件级完成条件：主线任务未终态时不能标记事件完成', (tester) async {
    app.ws.createTask(eventId: eventId, title: '还没做完的任务');

    await openBoard2(tester);

    final check = app.ws.checkEventCompletion(eventId);
    expect(check.canComplete, isFalse);
    expect(check.reason, contains('未处理'));

    // 任务全部进入终态后即可完成
    final task = app.ws.mainLineOf(eventId).single;
    app.ws.setTaskStatus(task.id, NodeStatus.ignored);
    expect(app.ws.checkEventCompletion(eventId).canComplete, isTrue);
  });

  testWidgets('空任务线给出引导', (tester) async {
    await openBoard2(tester);

    expect(find.text('这条任务线还是空的'), findsOneWidget);
    expect(find.text('添加标准任务'), findsWidgets);
  });

  testWidgets('逾期任务在卡片上显示强调标记', (tester) async {
    final task = app.ws.createTask(eventId: eventId, title: '拖了很久的任务');
    app.ws.updateTask(task.id, dueAt: '2020-01-01');

    await openBoard2(tester);

    expect(find.text('2020-01-01'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsWidgets, reason: '逾期要有视觉提醒（Q48）');
  });
}
