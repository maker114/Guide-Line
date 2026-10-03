import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/ids.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/format.dart';
import 'package:guideline/ui/common/inline_editor.dart';

/// 任务行的入口与"被挡住"的表达（灵感 14 / 15）：
///   · 还有未处理子任务时，状态按钮换**锁形**，点它不改变状态、只解释原因；
///   · 子任务没勾完时，父任务不能被直接完成；
///   · 任务行上只留一个图标按钮「设到期日」，其余动作走点整行弹出的面板；
///   · Q27：动作面板能改归属（提到主线 / 挂到某个节点下），与"改归属"配套的
///     上下挪一格到两端时要给一句反馈。
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

  /// 日历网格里**第一个能点的日号**（1~28 一定每个月都有，闰月也不怕）。
  ///
  /// 不写死"点 15 号"那类断言：日历显示的是当前月，写死的日号会随运行日期漂。
  Finder firstTappableDay(WidgetTester tester) {
    final days = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data != null &&
          int.tryParse(widget.data!) != null &&
          int.parse(widget.data!) >= 1 &&
          int.parse(widget.data!) <= 28,
    );
    return days.first;
  }

  /// 点开一个 `InlineComposer` 并提交一条。
  ///
  /// 输入框用**当前获得焦点的那一个**定位，不用 `.last`：展开过的输入行会留在
  /// 树里，先后顺序与你想点的那一行并不一致 —— `app_smoke_test` 在那里踩过一次
  /// （文字输进了另一行、任务根本没建出来）。
  Future<void> submitInlineComposer(
    WidgetTester tester,
    String label,
    String text,
  ) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();

    final focused = find.byWidgetPredicate(
      (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
      description: '当前获得焦点的输入框',
    );
    expect(focused, findsOneWidget, reason: '点开「$label」后应有一个输入框获得焦点');

    await tester.enterText(focused, text);
    final composer = find.ancestor(of: focused, matching: find.byType(InlineComposer));
    await tester.tap(find.descendant(of: composer, matching: find.byTooltip('添加')));
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

    expect(find.byIcon(Icons.event_outlined), findsOneWidget, reason: '没排期时是"设到期日"');
    // 「接后续任务…」那个折线入口跟着分叉 / 合流一起删了：链上不再有"走向"
    expect(find.byIcon(Icons.timeline), findsNothing);

    // 点开的是**日期面板**（日历本体 + 底部动作），不是系统的 `showDatePicker`
    await tester.tap(find.byIcon(Icons.event_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarDatePicker), findsOneWidget);
  });

  testWidgets('日期面板里选一天 → 真的设上到期日', (tester) async {
    final app = await appWithTask(withSubtask: false);
    await openEvent(tester, app);

    await tester.tap(find.byIcon(Icons.event_outlined));
    await tester.pumpAndSettle();
    expect(find.text('现在还没有日期'), findsOneWidget, reason: '没设过就说清"还没有"');
    expect(find.text('清除日期'), findsNothing, reason: '没有值就不该出现清除键');
    // 2026-10-02：没有日期时也不给「选时间…」—— 那一天还不存在，谈几点都早
    expect(find.text('选时间…'), findsNothing);

    await tester.tap(firstTappableDay(tester));
    await tester.pumpAndSettle();

    final due = app.ws.liveTasks.single.dueAt;
    expect(due, isNotNull, reason: '选了那一天就该落盘');
    expect(
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(due!),
      isTrue,
      reason: '只点日历某天 ⇒ 仍然是纯日期，不凭空补一个时刻',
    );
    expect(find.byIcon(Icons.event_available_outlined), findsOneWidget, reason: '图标换成"已设"');
  });

  // ── 截止时间精确到分钟（2026-10-02，用户："允许设定截止时间精确到分钟"）──

  testWidgets('已有日期的面板上能补一个时刻，值变成「YYYY-MM-DD HH:mm」', (tester) async {
    final app = await appWithTask(withSubtask: false);
    final task = app.ws.liveTasks.single;
    app.run(() => app.ws.updateTask(task.id, dueAt: '2099-05-01'));

    await openEvent(tester, app);
    await tester.tap(find.byIcon(Icons.event_available_outlined));
    await tester.pumpAndSettle();

    // 纯日期的值上，时间键写「选时间…」，而**不该**有「清除时间」
    // （那会让用户以为这条已经有时刻了）
    expect(find.text('选时间…'), findsOneWidget);
    expect(find.text('清除时间'), findsNothing);

    await tester.tap(find.text('选时间…'));
    await tester.pumpAndSettle();
    // Material 的时间选择器：表盘是 5 分钟一格（用户口径"只需要 5 分钟"）
    expect(find.byType(TimePickerDialog), findsOneWidget);

    // 确定键的文案跟 locale 走，**不写死**（写死过一次，不同语言下会找不到）。
    // 直接问 `MaterialLocalizations` 要它打算显示的那两个字。
    final l10n = MaterialLocalizations.of(
      tester.element(find.byType(TimePickerDialog)),
    );
    await tester.tap(find.text(l10n.okButtonLabel));
    await tester.pumpAndSettle();

    final due = app.ws.liveTasks.single.dueAt!;
    expect(
      RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$').hasMatch(due),
      isTrue,
      reason: '选完时刻之后落盘的就是带 HH:mm 的值：$due',
    );
    expect(Ids.hasTimeOfDay(due), isTrue);
    expect(parseIsoDateTime(due), isNotNull, reason: '必须能被同一把尺子解析回去');
  });

  testWidgets('带时刻的值：面板预填那个时刻，也能「清除时间」退回纯日期', (tester) async {
    final app = await appWithTask(withSubtask: false);
    final task = app.ws.liveTasks.single;
    app.run(() => app.ws.updateTask(task.id, dueAt: '2099-05-01 14:35'));

    await openEvent(tester, app);
    await tester.tap(find.byIcon(Icons.event_available_outlined));
    await tester.pumpAndSettle();

    // 有时刻 ⇒ 键上显示当前时刻、并且多出「清除时间」
    expect(find.text('时间 14:35'), findsOneWidget);
    expect(find.text('清除时间'), findsOneWidget);
    expect(find.textContaining('2099-05-01 14:35'), findsWidgets, reason: '当前值要带时刻');

    await tester.tap(find.text('清除时间'));
    await tester.pumpAndSettle();

    expect(
      app.ws.liveTasks.single.dueAt,
      '2099-05-01',
      reason: '清除时间只脱掉时刻那一段，日子留着',
    );
  });

  testWidgets('日期面板底部的「清除日期」真的把到期日清掉（实机反馈：设了取消不掉）',
      (tester) async {
    final app = await appWithTask(withSubtask: false);
    final task = app.ws.liveTasks.single;
    app.run(() => app.ws.updateTask(task.id, dueAt: '2099-05-01'));

    await openEvent(tester, app);
    await tester.tap(find.byIcon(Icons.event_available_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前：'), findsOneWidget, reason: '有值时报出当前值');
    await tester.tap(find.text('清除日期'));
    await tester.pumpAndSettle();

    expect(app.ws.liveTasks.single.dueAt, isNull, reason: '清除键必须真的清得掉');
    expect(find.byIcon(Icons.event_outlined), findsOneWidget, reason: '图标回到"没排期"');
  });

  testWidgets('到期日的两个动作都只在日期面板里，动作面板里不再有日期项', (tester) async {
    final app = await appWithTask(withSubtask: false);
    final task = app.ws.liveTasks.single;
    app.run(() => app.ws.updateTask(task.id, dueAt: '2099-05-01'));

    await openEvent(tester, app);
    await tester.tap(find.text('主线任务'));
    await tester.pumpAndSettle();

    expect(
      find.text('清除到期日'),
      findsNothing,
      reason: '实机反馈：改日期与清除日期都收进图标里，不要再挂在动作面板下',
    );
  });

  testWidgets('任务行尾那个到期日图标不贴边：离卡片右缘留出余量', (tester) async {
    final app = await appWithTask(withSubtask: false);
    await openEvent(tester, app);

    // 任务行那一整条（含它自己的内边距）与里面那颗日历图标的实际位置
    final tile = tester.getRect(find.byType(ListTile).first);
    final icon = tester.getRect(find.byIcon(Icons.event_outlined));

    expect(
      tile.right - icon.right,
      greaterThanOrEqualTo(12),
      reason: '行尾图标原本 contentPadding.right = 0，贴着行尾看着要掉出屏幕（实机反馈）',
    );
  });

  testWidgets('动作面板里只剩下"加一条 / 改这一条"的动作，没有走向类入口', (tester) async {
    final app = await appWithTask(withSubtask: true);
    await openEvent(tester, app);

    await tester.tap(find.text('主线任务'));
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

    expect(find.byIcon(Icons.event_available_outlined), findsOneWidget);
    expect(
      find.textContaining('2099-05-01'),
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

    await tester.tap(find.text('主线任务'));
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
    await tester.tap(find.text('第一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('往上挪一格'));
    await tester.pumpAndSettle();
    expect(find.text('已经是最前面了'), findsOneWidget);

    // 让上面那条轻提示先退场（`ScaffoldMessenger` 一次只显示一条，后面的要排队）
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // 最后一个节点往下挪：也到头了
    await tester.tap(find.text('第二步'));
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

  // ---------------------------------------------------------------------------
  // 「插在它后面」（2026-10-03 / ADR-096）：从前加节点只有链尾一条路，
  // 想插在中间只能先建到末尾、再一格格往上挪。
  // ---------------------------------------------------------------------------

  testWidgets('主线节点的动作面板里有「在后面插一条主线任务」', (tester) async {
    final app = await appWithTask(withSubtask: false);
    await openEvent(tester, app);

    await tester.tap(find.text('主线任务'));
    await tester.pumpAndSettle();

    expect(
      find.text('在后面插一条主线任务'),
      findsOneWidget,
      reason: '链上节点才有"它后面"这回事',
    );
  });

  testWidgets('子任务行的动作面板里**没有**这一项（子任务不参与链上顺序）', (tester) async {
    final app = await appWithTask(withSubtask: true);
    await openEvent(tester, app);

    await tester.tap(find.text('子任务甲'));
    await tester.pumpAndSettle();

    expect(find.text('在后面插一条主线任务'), findsNothing);
    expect(find.text('往上挪一格'), findsNothing, reason: '与"往上 / 往下挪一格"同一个条件');
  });

  testWidgets('点它 → 在该节点下方长出输入行 → 建成后夹在锚点与后一条之间', (tester) async {
    final app = await appWithTask(withSubtask: false);
    final event = app.ws.liveEvents.single;
    app.ws.createTask(eventId: event.id, title: '第二条');
    await openEvent(tester, app);

    await tester.tap(find.text('主线任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在后面插一条主线任务'));
    await tester.pumpAndSettle();

    expect(find.text('插在它后面'), findsOneWidget, reason: '输入行就地长在锚点下方');

    await submitInlineComposer(tester, '插在它后面', '夹在中间的一条');

    expect(
      app.ws.mainLineOf(event.id).map((t) => t.title),
      <String>['主线任务', '夹在中间的一条', '第二条'],
      reason: '不是排到末尾 —— "排到末尾"那条路一直都在，这里要的是插在它后面',
    );
    expect(find.text('夹在中间的一条'), findsOneWidget, reason: '新节点当场画在任务线上');
    expect(find.text('插在它后面'), findsNothing, reason: '建完就把输入行收起来');
  });
}
