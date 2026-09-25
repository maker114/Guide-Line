import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/events/event_detail_page.dart';
import 'package:guideline/ui/events/task_fold.dart';

/// 事件页改成"与项目页同一套观感"之后的接线：
///   · 一个事件一张卡，卡里嵌着主线任务（不用点进去就能看到做到哪）；
///   · 已完成的节点自动收起，只留当前节点的上一个（规则与详情页共用）；
///   · 卡头能展开 / 收起整条线。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_event_tab_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('autoFoldedMainLineIds（列表页与详情页共用的规则）', () {
    Task task(String id, NodeStatus status) => Task(
          id: id,
          eventId: 'e1',
          parentTaskId: null,
          taskType: TaskType.standard,
          title: '任务 $id',
          dueAt: null,
          status: status,
          archived: false,
          order: 1000,
          completedAt: status == NodeStatus.done ? 1700000000000 : null,
          createdAt: 1700000000000,
          updatedAt: 1700000000000,
          deleted: false,
        );

    test('只收起"当前节点上一个"之前的已完成节点', () {
      final folded = autoFoldedMainLineIds(<Task>[
        task('a', NodeStatus.done),
        task('b', NodeStatus.done),
        task('c', NodeStatus.done),
        task('d', NodeStatus.pending),
      ]);
      expect(folded, <String>{'a', 'b'}, reason: 'c 是当前节点（d）的上一个，要留着');
    });

    test('全是终态就不折（否则整条线会消失）', () {
      expect(
        autoFoldedMainLineIds(<Task>[
          task('a', NodeStatus.done),
          task('b', NodeStatus.ignored),
        ]),
        isEmpty,
      );
    });

    test('空线、以及当前节点就在第一位时都不折', () {
      expect(autoFoldedMainLineIds(<Task>[]), isEmpty);
      expect(
        autoFoldedMainLineIds(<Task>[
          task('a', NodeStatus.pending),
          task('b', NodeStatus.pending),
        ]),
        isEmpty,
      );
    });

    test('用户手动展开过的节点有豁免', () {
      final folded = autoFoldedMainLineIds(
        <Task>[
          task('a', NodeStatus.done),
          task('b', NodeStatus.done),
          task('c', NodeStatus.pending),
        ],
        userExpanded: (id) => id == 'a',
      );
      expect(folded, isEmpty, reason: 'a 被显式展开过，就不该再被自动收起');
    });
  });

  Future<AppController> bootWithLine(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '秋季发布');
    for (final title in <String>['第一步', '第二步', '第三步', '第四步']) {
      final task = app.ws.createTask(eventId: event.id, title: title);
      if (title != '第四步') {
        app.run(() => app.ws.setTaskStatus(task.id, NodeStatus.done));
      }
    }
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('事件卡里直接列出主线任务，且已完成的自动收起', (tester) async {
    await bootWithLine(tester);

    // 卡头一眼看到进度
    expect(find.text('主线 3/4'), findsOneWidget);
    expect(find.textContaining('当前 · 第四步'), findsOneWidget);

    // 卡里嵌着任务：当前节点与它的上一个看得见
    expect(find.text('第四步'), findsOneWidget);
    expect(find.text('第三步'), findsOneWidget);
    // 更早的已完成节点被收起，并明说收了几条
    expect(find.text('第一步'), findsNothing);
    expect(find.text('第二步'), findsNothing);
    expect(find.textContaining('另有 2 个已完成节点'), findsOneWidget);
  });

  testWidgets('卡头能收起整条线，再点一次展开', (tester) async {
    final app = await bootWithLine(tester);
    final event = app.ws.liveEvents.single;

    expect(find.text('第四步'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_more).first);
    await tester.pumpAndSettle();
    expect(find.text('第四步'), findsNothing, reason: '收起后卡里不该还有任务行');
    expect(app.isExpanded(event.id), isFalse, reason: '折叠状态要记进偏好');

    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    expect(find.text('第四步'), findsOneWidget);
    expect(app.isExpanded(event.id), isTrue);
  });

  testWidgets('1.6 倍字体 + 很长的标题：事件卡不溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一个名字相当长的事件名，用来撑满一行看看会不会挤爆');
    for (var i = 1; i <= 8; i += 1) {
      final task = app.ws.createTask(
        eventId: event.id,
        title: '第 $i 步：一条名字相当长的主线任务标题',
      );
      if (i <= 6) app.run(() => app.ws.setTaskStatus(task.id, NodeStatus.done));
    }

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '布局溢出会在这里抛出来');
    expect(find.textContaining('另有 5 个已完成节点'), findsOneWidget);
  });

  testWidgets('点卡里的任务行同样能进事件详情', (tester) async {
    await bootWithLine(tester);

    await tester.tap(find.text('第四步'));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailPage), findsOneWidget);
  });

  testWidgets('已搁置的事件：日期不再标成逾期红，也不计入「到期」', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final dropped = app.ws.createEvent(name: '放下的事');
    final droppedTask = app.ws.createTask(eventId: dropped.id, title: '搁置线的任务');
    app.run(() => app.ws.updateTask(droppedTask.id, dueAt: '2020-01-01'));
    app.run(() => app.ws.setEventStatus(dropped.id, NodeStatus.ignored));

    final active = app.ws.createEvent(name: '还在做的事');
    final activeTask = app.ws.createTask(eventId: active.id, title: '进行中线的任务');
    app.run(() => app.ws.updateTask(activeTask.id, dueAt: '2020-01-01'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.text('搁置线的任务'))).colorScheme;
    // 日期文案是「逾期 N 天」（`describeDate`），两条各一份
    final overdueTexts = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.data?.startsWith('逾期') ?? false)
        .toList(growable: false);
    expect(overdueTexts.length, 2, reason: '两条任务都有日期');

    Color? colorOf(String taskTitle) {
      final row = find.ancestor(
        of: find.text(taskTitle),
        matching: find.byType(ListTile),
      );
      final text = tester.widget<Text>(
        find.descendant(of: row, matching: find.textContaining('逾期')),
      );
      return text.style?.color;
    }

    expect(colorOf('进行中线的任务'), scheme.error, reason: '在进行的事件里，逾期就该标红');
    expect(colorOf('搁置线的任务'), isNot(scheme.error), reason: '搁置了就不该再催');

    // 数据层：搁置事件下的任务不进「到期」聚合
    final due = app.ws.tasksDueOnOrBefore('2030-01-01');
    expect(due.map((t) => t.title), <String>['进行中线的任务']);
  });
}
