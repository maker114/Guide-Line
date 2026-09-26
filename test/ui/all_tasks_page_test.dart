import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/ids.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/common/format.dart';
import 'package:guideline/ui/more/all_tasks_page.dart';

/// 「全部任务」的这几条：
///   · 顶上那排「全部 / 未完成 / 已完成 / 已搁置」分类**整行去掉**；
///   · 任务行：**左边只放任务名**，箭头没了，**到期日与完成圆钮靠右对齐**，
///     所属事件仍在名字下面那一行；
///   · Q26：多选（长按进入、点条目切换、「全选」只作用于当前可见项）+
///     批量设到期日 / 批量归档。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_all_tasks_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  Future<void> openAllTasks(WidgetTester tester, AppController app) async {
    await tester.pumpWidget(MaterialApp(home: AllTasksPage(app: app)));
    await tester.pumpAndSettle();
  }

  testWidgets('顶上不再有「全部 / 未完成 / 已完成 / 已搁置」这排分类', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(eventId: event.id, title: '一条任务', dueAt: dateOffset(3)));

    await openAllTasks(tester, app);

    expect(find.byType(FilterChip), findsNothing, reason: '分类条整行去掉');
    expect(find.textContaining('全部 '), findsNothing);
    // 分组调节栏还在（换成全应用统一的胶囊选择器）
    expect(find.text('按完成度'), findsOneWidget);
    expect(find.text('按事件'), findsOneWidget);
    expect(find.text('按紧迫度'), findsOneWidget);
    expect(find.text('共 1 条（含子任务）'), findsOneWidget);
  });

  testWidgets('任务行：完成圆钮在左，到期日靠右在第二行，第一行只有任务名，没有箭头', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(eventId: event.id, title: '写解析层', dueAt: dateOffset(3)));

    await openAllTasks(tester, app);

    final title = tester.getRect(find.text('写解析层'));
    final due = tester.getRect(find.textContaining('3 天后'));
    final button = tester.getRect(find.byIcon(Icons.radio_button_unchecked));
    final eventLabel = tester.getRect(find.text('一件事'));

    expect(button.left, lessThan(title.left), reason: '完成圆钮在最左边（原先的位置）');
    expect(
      (due.center.dy - eventLabel.center.dy).abs(),
      lessThan(8),
      reason: '到期日和所属事件在第二行',
    );
    expect(due.top, greaterThanOrEqualTo(title.bottom), reason: '它在任务名那一行的下面');
    expect(due.left, greaterThan(eventLabel.left), reason: '到期日靠右');
    expect(find.byIcon(Icons.chevron_right), findsNothing, reason: '箭头去掉了');
  });

  testWidgets('任务名比下面那行（所属事件）字号大一档', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(eventId: event.id, title: '写解析层'));

    await openAllTasks(tester, app);

    final titleSize = tester.widget<Text>(find.text('写解析层')).style?.fontSize;
    final eventSize = tester.widget<Text>(find.text('一件事')).style?.fontSize;
    expect(titleSize, isNotNull);
    expect(eventSize, isNotNull);
    expect(titleSize!, greaterThan(eventSize!), reason: '主次靠字号分开');
  });

  testWidgets('子任务行只显示子任务名，不带父任务名与「子任务」标签', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final main = app.ws.createTask(eventId: event.id, title: '主线任务');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '子任务甲',
          parentTaskId: main.id,
          type: TaskType.subtask,
        ));

    await openAllTasks(tester, app);

    expect(find.text('子任务甲'), findsOneWidget);
    expect(find.text('主线任务'), findsOneWidget, reason: '父任务自己有自己的一行');
    expect(find.text('· 主线任务'), findsNothing, reason: '子任务行不该再拖一条父任务名的尾巴');
    expect(find.text('· 子任务'), findsNothing, reason: '「子任务」这个标签也不再显示');
  });

  testWidgets('按完成度分组：三档顺序固定，切到按事件也照常', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final pending = app.ws.createTask(eventId: event.id, title: '还欠着');
    app.run(() => app.ws.createTask(eventId: event.id, title: '做完了'));
    app.run(() => app.ws.setTaskStatus(
          app.ws.liveTasks.firstWhere((t) => t.title == '做完了').id,
          NodeStatus.done,
        ));

    await openAllTasks(tester, app);

    expect(find.text('未完成'), findsWidgets);
    expect(find.text('已完成'), findsWidgets);
    final pendingY = tester.getRect(find.text('还欠着')).top;
    final doneY = tester.getRect(find.text('做完了')).top;
    expect(pendingY, lessThan(doneY), reason: '未完成排最前、已完成最后');
    expect(pending.id, isNotEmpty);

    await tester.tap(find.text('按事件'));
    await tester.pumpAndSettle();
    expect(find.text('一件事'), findsWidgets, reason: '按事件分组时组头是事件名');
  });

  testWidgets('按事件分组：组内也是未完成 → 已搁置 → 已完成，同档按到期日', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final pending = app.ws.createTask(eventId: event.id, title: '还欠着', dueAt: dateOffset(2));
    final done = app.ws.createTask(eventId: event.id, title: '做完了', dueAt: dateOffset(1));
    app.run(() => app.ws.setTaskStatus(done.id, NodeStatus.done));
    final ignored = app.ws.createTask(eventId: event.id, title: '搁置了', dueAt: dateOffset(3));
    app.run(() => app.ws.setTaskStatus(ignored.id, NodeStatus.ignored));

    await openAllTasks(tester, app);
    await tester.tap(find.text('按事件'));
    await tester.pumpAndSettle();

    final pendingY = tester.getRect(find.text('还欠着')).top;
    final ignoredY = tester.getRect(find.text('搁置了')).top;
    final doneY = tester.getRect(find.text('做完了')).top;
    expect(pendingY, lessThan(ignoredY), reason: '未完成最前');
    expect(ignoredY, lessThan(doneY), reason: '已搁置居中、已完成最后');
    expect(pending.id, isNotEmpty);
  });

  testWidgets('两行任务之间的间距够紧凑（实机反馈：再小一点）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(eventId: event.id, title: '第一条', dueAt: dateOffset(3)));
    app.run(() => app.ws.createTask(eventId: event.id, title: '第二条', dueAt: dateOffset(4)));

    await openAllTasks(tester, app);

    final first = tester.getRect(find.text('第一条'));
    final second = tester.getRect(find.text('第二条'));
    final pitch = second.center.dy - first.center.dy;
    expect(pitch, lessThan(66), reason: '任务行比 Material 默认的两行列表（72）更紧');
  });

  testWidgets('深色 + 1.6 倍字体、窄屏下这一行不溢出（右边是要挤在一起的东西）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await boot();
    final event = app.ws.createEvent(name: '一个名字相当长的事件名');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '一条名字相当长的主线任务名',
          dueAt: dateOffset(3),
        ));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AllTasksPage(app: app),
      ),
    );
    await tester.pumpAndSettle();

    // 溢出会以 FlutterError 的形式让这条用例失败；这里再确认三样东西都在
    expect(find.textContaining('3 天后'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('多选两条 → 批量设到期日：两条都变了、也落了盘（Q26）', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final first = app.ws.createTask(eventId: event.id, title: '第一条');
    final second = app.ws.createTask(eventId: event.id, title: '第二条');

    await openAllTasks(tester, app);

    // 长按进入多选（与灵感页同一套习惯）
    await tester.longPress(find.text('第一条'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);

    // 多选里点条目 = 切换选中（不再进事件详情）。
    // 这时整行由 `AbsorbPointer` 接管，点的落点是那一行而不是文字，
    // 所以关掉"没点到文字"的提醒。
    await tester.tap(find.text('第二条'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.byTooltip('设到期日'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    // 选择器初值就是今天，直接确认 → 两条都设成今天
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final today = Ids.todayDate();
    expect(app.ws.findTask(first.id)!.dueAt, today);
    expect(app.ws.findTask(second.id)!.dueAt, today);
    expect(find.text('已选 2 条'), findsNothing, reason: '成功之后退出多选');

    // 落盘：重新装配一次还读得到
    final reloaded = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(reloaded.ws.findTask(first.id)!.dueAt, today);
    expect(reloaded.ws.findTask(second.id)!.dueAt, today);
  });

  testWidgets('批量归档：二次确认说清影响条数（含子任务），确认后父子一起归档（Q26）', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final main = app.ws.createTask(eventId: event.id, title: '主线任务');
    final child = app.ws.createTask(
      eventId: event.id,
      title: '子任务甲',
      parentTaskId: main.id,
      type: TaskType.subtask,
    );
    final other = app.ws.createTask(eventId: event.id, title: '另一条');

    await openAllTasks(tester, app);

    await tester.longPress(find.text('主线任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('另一条'), warnIfMissed: false);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('归档'));
    await tester.pumpAndSettle();
    // 归档是级联的："我选了 2 条"与"一共动了 3 条"必须都说清
    expect(find.textContaining('连同它们的子任务一共 3 条'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '归档'));
    await tester.pumpAndSettle();

    expect(app.ws.findTask(main.id)!.archived, isTrue);
    expect(app.ws.findTask(child.id)!.archived, isTrue, reason: '归档级联子任务');
    expect(app.ws.findTask(other.id)!.archived, isTrue);

    // 落盘
    final reloaded = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(reloaded.ws.findTask(child.id)!.archived, isTrue);
  });

  testWidgets('批量归档里有一条已经归档（数据在别处变了）：整批不动并说明原因（Q26）', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final first = app.ws.createTask(eventId: event.id, title: '第一条');
    final second = app.ws.createTask(eventId: event.id, title: '第二条');

    await openAllTasks(tester, app);
    await tester.longPress(find.text('第一条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二条'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // 模拟"数据在别处变了"：直接改数据层（不走 `app.run`，所以这一帧界面还没重建）
    app.ws.setTaskArchived(second.id, true);

    await tester.tap(find.byTooltip('归档'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '归档'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已经归档过了'), findsOneWidget, reason: '要给出可读原因');
    expect(app.ws.findTask(first.id)!.archived, isFalse, reason: '一条不合法就整批不动');
  });

  testWidgets('「全选」按当前可见项算，也能一键取消（Q26）', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(eventId: event.id, title: '第一条'));
    app.run(() => app.ws.createTask(eventId: event.id, title: '第二条'));

    await openAllTasks(tester, app);
    await tester.longPress(find.text('第一条'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsOneWidget);
  });
}
