import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/common/format.dart';
import 'package:guideline/ui/more/all_tasks_page.dart';

/// 「全部任务」的这两条（实机反馈）：
///   · 顶上那排「全部 / 未完成 / 已完成 / 已搁置」分类**整行去掉**；
///   · 任务行：**左边只放任务名**，箭头没了，**到期日与完成圆钮靠右对齐**，
///     所属事件仍在名字下面那一行。
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
}
