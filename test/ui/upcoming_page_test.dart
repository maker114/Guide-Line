import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/ui/common/color_picker.dart';
import 'package:guideline/ui/common/format.dart';
import 'package:guideline/ui/more/task_calendar_page.dart';
import 'package:guideline/ui/more/upcoming_page.dart';

/// 「接下来的任务」（实机反馈：由原来的「到期」改过来）：
///   · 列表 = 「全部任务」的**按紧迫度分组**，但只列未完成 ——
///     已搁置 / 已完成不出现；
///   · 右上角一个「日历」按钮，打开按月排的任务日历；
///   · 日历上每个有任务的日期画一圈圆环，颜色 = 所属**事件标识色**，
///     一天有几条任务就分成几段；点一天能看到那天的任务。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_upcoming_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  Future<void> openUpcoming(WidgetTester tester, AppController app) async {
    await tester.pumpWidget(MaterialApp(home: UpcomingTasksPage(app: app)));
    await tester.pumpAndSettle();
  }

  Future<void> openCalendar(WidgetTester tester, AppController app) async {
    await openUpcoming(tester, app);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
  }

  testWidgets('按紧迫度分组，只列未完成：已搁置与已完成不出现', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(eventId: event.id, title: '逾期的', dueAt: dateOffset(-2)));
    app.run(() => app.ws.createTask(eventId: event.id, title: '今天的', dueAt: dateOffset(0)));
    app.run(() => app.ws.createTask(eventId: event.id, title: '没排期的'));
    final done = app.ws.createTask(eventId: event.id, title: '做完了', dueAt: dateOffset(-1));
    final ignored = app.ws.createTask(eventId: event.id, title: '搁置了', dueAt: dateOffset(-1));
    app.run(() => app.ws.setTaskStatus(done.id, NodeStatus.done));
    app.run(() => app.ws.setTaskStatus(ignored.id, NodeStatus.ignored));

    await openUpcoming(tester, app);

    // 分档依次是：已逾期 → 今天 → 没有到期日
    final overdueY = tester.getRect(find.text('已逾期')).top;
    final todayY = tester.getRect(find.text('今天')).top;
    final noneY = tester.getRect(find.text('没有到期日')).top;
    expect(overdueY, lessThan(todayY));
    expect(todayY, lessThan(noneY));

    expect(find.text('逾期的'), findsOneWidget);
    expect(find.text('今天的'), findsOneWidget);
    expect(find.text('没排期的'), findsOneWidget);
    expect(find.text('做完了'), findsNothing, reason: '已完成不出现');
    expect(find.text('搁置了'), findsNothing, reason: '已搁置不出现');
    expect(find.text('已完成 / 已搁置'), findsNothing, reason: '连分组头都不该有');
  });

  testWidgets('已搁置事件下的任务**照样列出**（这一页不是催办，是"我还欠着什么"）', (tester) async {
    // 实机反馈踩到的坑：原来这里跳过了"已搁置的事件"下的任务（从「到期」继承
    // 过来的规则），结果 9 条未完成的任务全被藏掉、整页空空如也。
    // 那条规则只在**催办**的地方生效（逾期角标 / 启动横幅）。
    final app = await boot();
    final dropped = app.ws.createEvent(name: '先不做了');
    app.run(() => app.ws.createTask(eventId: dropped.id, title: '搁置线里的任务', dueAt: dateOffset(-1)));
    app.run(() => app.ws.setEventStatus(dropped.id, NodeStatus.ignored));

    await openUpcoming(tester, app);

    expect(find.text('搁置线里的任务'), findsOneWidget);
    expect(find.textContaining('接下来没有待办'), findsNothing);
    // 但"催办"那一侧仍然排除它：逾期角标不该被放下的线拉响
    expect(app.overdueCount, 0);
  });

  testWidgets('空的时候把"为什么空"说清楚（逐条对上筛选口径）', (tester) async {
    final app = await boot();
    final live = app.ws.createEvent(name: '还开着的线');
    final done = app.ws.createTask(eventId: live.id, title: '做完了');
    final ignored = app.ws.createTask(eventId: live.id, title: '搁置了');
    app.run(() => app.ws.setTaskStatus(done.id, NodeStatus.done));
    app.run(() => app.ws.setTaskStatus(ignored.id, NodeStatus.ignored));

    await openUpcoming(tester, app);

    expect(find.textContaining('共 2 条任务'), findsOneWidget);
    expect(find.textContaining('已完成 1 条'), findsOneWidget);
    expect(find.textContaining('已搁置 1 条'), findsOneWidget);
    expect(find.textContaining('这一页只列未完成的任务'), findsOneWidget);
  });

  testWidgets('「日历」按钮打开任务日历，点一天能看到那天的任务', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(eventId: event.id, title: '那天的任务', dueAt: dateOffset(2)));

    await openCalendar(tester, app);

    expect(find.text('日历'), findsOneWidget);
    final date = dateOffset(2);
    expect(find.byKey(calendarDayKey(date)), findsOneWidget);

    await tester.tap(find.byKey(calendarDayKey(date)));
    await tester.pumpAndSettle();

    expect(find.textContaining(monthDayLabel(date)), findsOneWidget, reason: '下面列出这一天的日期');
    expect(find.text('那天的任务'), findsOneWidget);
  });

  testWidgets('日历只标"还开着"的任务；没排期的单独提示', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final done = app.ws.createTask(eventId: event.id, title: '做完的', dueAt: dateOffset(1));
    app.run(() => app.ws.setTaskStatus(done.id, NodeStatus.done));
    app.run(() => app.ws.createTask(eventId: event.id, title: '没排期'));

    await openCalendar(tester, app);

    final date = dateOffset(1);
    final marks = taskMarksByDate(
      app.ws.openTasks(),
      (task) => app.ws.findEvent(task.eventId)?.color,
      const Color(0xFF000000),
    );
    expect(marks.containsKey(date), isFalse, reason: '已完成不画环');
    expect(find.textContaining('另有 1 条没排期'), findsOneWidget);
  });

  group('日期 → 圆环颜色（纯函数）', () {
    const fallback = Color(0xFF111111);

    testWidgets('一天一条任务：一段色；两条：两段', (tester) async {
      final app = await boot();
      final first = app.ws.createEvent(name: '甲');
      final second = app.ws.createEvent(name: '乙');
      app.run(() => app.ws.setEventColor(first.id, '#78d2ca'));
      app.run(() => app.ws.setEventColor(second.id, '#a85780'));
      final t1 = app.ws.createTask(eventId: first.id, title: '甲的任务', dueAt: '2026-09-28');
      final t2 = app.ws.createTask(eventId: second.id, title: '乙的任务', dueAt: '2026-09-28');

      final marks = taskMarksByDate(
        <Task>[t1, t2],
        (task) => app.ws.findEvent(task.eventId)?.color,
        fallback,
      );

      expect(marks['2026-09-28']!.length, 2, reason: '两条任务 = 两段弧（各占一半）');
      expect(marks['2026-09-28']!.first, colorOfHex('#78d2ca'));
      expect(marks['2026-09-28']!.last, colorOfHex('#a85780'));
    });

    testWidgets('事件没设色：退回中性灰；同一天三条就是三段', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '没色的');
      app.run(() => app.ws.setEventColor(event.id, null));
      final tasks = <Task>[
        app.ws.createTask(eventId: event.id, title: '一', dueAt: '2026-09-28'),
        app.ws.createTask(eventId: event.id, title: '二', dueAt: '2026-09-28'),
        app.ws.createTask(eventId: event.id, title: '三', dueAt: '2026-09-28'),
        app.ws.createTask(eventId: event.id, title: '没排期'),
      ];

      final marks = taskMarksByDate(
        tasks,
        (task) => app.ws.findEvent(task.eventId)?.color,
        fallback,
      );

      expect(marks['2026-09-28']!.length, 3);
      expect(marks['2026-09-28']!.every((c) => c == fallback), isTrue);
      expect(marks.keys, <String>['2026-09-28'], reason: '没排期的不进日历');
    });
  });

  group('日历格子本身', () {
    testWidgets('有任务的那天画圆环，没有的不画', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '一件事');
      app.run(() => app.ws.setEventColor(event.id, '#78d2ca'));
      app.run(() => app.ws.createTask(eventId: event.id, title: '那天的', dueAt: dateOffset(0)));

      await openCalendar(tester, app);

      final rings = tester.widgetList<DayRing>(find.byType(DayRing));
      final withRing = rings.where((r) => r.colors.isNotEmpty).length;
      expect(withRing, 1, reason: '只有今天那一格有环');
    });
  });
}
