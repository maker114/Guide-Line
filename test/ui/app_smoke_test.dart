import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/inline_editor.dart';

import 'scroll_finders.dart';

/// 手机端界面冒烟测试：**把四个 Tab 的主干路径真的走一遍**。
///
/// 纯逻辑测试（`test/core/*`）保证规则对，这里保证**接线对**：
/// 用户点得下去的按钮真的能建出数据，并且数据真的落到磁盘上。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guideline_ui_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> switchTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('逾期提醒是内容区的卡片，不是贴在标题栏下的一条色带', (tester) async {
    // 实机反馈："顶部标题栏偶尔背景颜色不一样" —— 起因是那条通栏的提醒带
    // 紧贴标题栏、又用主题色铺满，看着像标题栏自己变了色。
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一件事');
    final task = app.ws.createTask(eventId: event.id, title: '过期的任务');
    app.run(() => app.ws.updateTask(task.id, dueAt: '2020-01-01'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    final banner = find.text('有 1 条任务已逾期');
    expect(banner, findsOneWidget);
    final rect = tester.getRect(banner);
    expect(rect.left, greaterThan(8), reason: '要有外边距 —— 通栏贴边就成了标题栏的一部分');
    expect(rect.right, lessThan(tester.view.physicalSize.width / tester.view.devicePixelRatio - 8));

    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.text('已逾期'), findsOneWidget, reason: '点它照旧进「到期」');
  });

  /// 走「页面内直接输入」：点开那一行 → 输入 → 点**那一行**的「添加」。
  ///
  /// 不能图省事用 `.last` 找输入框和按钮：已经展开的输入行会留在列表里，
  /// 而它们在树里的先后顺序与你想点的那个并不一致 ——
  /// 这里踩过一次，结果是文字输进了主线输入行、子任务根本没建出来。
  /// 所以用**当前获得焦点的那一行**来定位（展开时会自动聚焦）。
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

  testWidgets('灵感 → 项目 → 事件 → 更多 的主干流程可用，且数据落盘', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // ---- 1. 速记（默认 Tab）
    expect(find.text('「灵感」在此钉下一个锚点……'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '把灵感线做成一条链');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('把灵感线做成一条链'), findsOneWidget);
    expect(app.ws.inspirationInbox.length, 1);

    // ---- 2. 项目 Tab：页内直接输入建一个根项目
    await switchTab(tester, '项目');
    expect(find.text('还没有项目'), findsOneWidget);
    await submitInlineComposer(tester, '新建项目', 'Guide Line');
    expect(find.text('Guide Line'), findsOneWidget);
    expect(app.ws.liveProjects.length, 1);

    // ---- 3. 事件 Tab：页内直接输入建事件
    await switchTab(tester, '事件');
    expect(find.text('还没有事件'), findsOneWidget);
    await submitInlineComposer(tester, '新建事件', '手机端上线');
    expect(find.text('手机端上线'), findsOneWidget);
    expect(app.ws.liveEvents.length, 1);

    // 进任务线
    await tester.tap(find.text('手机端上线'));
    await tester.pumpAndSettle();
    expect(find.textContaining('这条任务线还是空的'), findsOneWidget);

    // 新建主线任务：现在是任务线末尾的页内输入行
    await submitInlineComposer(tester, '新建主线任务', '完成四个 Tab');
    expect(find.text('完成四个 Tab'), findsOneWidget);

    // 点任务行 → 动作面板 → 加一个子任务（验证框内渲染）
    // 「新建子任务」不再是对话框，而是在那个框内展开一行输入
    await tester.tap(find.text('完成四个 Tab'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建子任务'));
    await tester.pumpAndSettle();
    await submitInlineComposer(tester, '新建子任务', '子任务甲');
    // 先断数据再断界面：`find.text` 连输入框里的文字也算命中，
    // 万一提交没生效，只断文字会假通过（这里踩过一次）
    expect(
      app.ws.liveTasks.where((t) => t.parentId != null).length,
      1,
      reason: '子任务应该真的建出来了',
    );
    expect(find.text('子任务甲'), findsOneWidget);

    // 点状态按钮 = 完成（子任务先完成：父任务有未处理子任务时不允许直接完成）
    expect(find.text('下级 0/1'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).last);
    await tester.pumpAndSettle();
    expect(app.ws.liveTasks.where((t) => t.status == NodeStatus.done).length, 1);

    await tester.pageBack();
    await tester.pumpAndSettle();

    // ---- 4. 更多 Tab：聚合视图与数据安全页都能打开
    await switchTab(tester, '更多');
    await tester.tap(find.text('全部任务'));
    await tester.pumpAndSettle();
    expect(find.text('完成四个 Tab'), findsOneWidget);
    expect(find.text('子任务甲'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('归档区'));
    await tester.pumpAndSettle();
    expect(find.text('已归档 0'), findsOneWidget);
    expect(find.text('回收站 0'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 「更多」是一张会变长的列表，靠后的条目在小屏上不会被构建出来 ——
    // 所以要先滚到它可见再点，不能直接 tap（这里踩过一次）。
    // 滚动体必须点名：外壳的 `PageView`（左右滑动切页）也是一个 `Scrollable`，
    // 不指定的话默认那个 finder 会一次找到两个、直接抛 "Too many elements"。
    await tester.scrollUntilVisible(
      find.text('备份与恢复'),
      120,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份与恢复'));
    await tester.pumpAndSettle();
    expect(find.text('立即备份一份'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // ---- 5. 数据真的在磁盘上（单文件存储）
    final store = File('${tempDir.path}${Platform.pathSeparator}guideline.json');
    expect(store.existsSync(), isTrue, reason: '每次变更都应原子落盘');
    final text = store.readAsStringSync();
    expect(text.contains('把灵感线做成一条链'), isTrue);
    expect(text.contains('Guide Line'), isTrue);
    expect(text.contains('完成四个 Tab'), isTrue);
    expect(text.contains('子任务甲'), isTrue);
    expect(text.contains('"schemaVersion": 2'), isTrue);
  });

  testWidgets('搜索能跨四类实体命中', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.run(() => app.ws.createProject(title: '指南线'));
    app.run(() => app.ws.captureInspiration('指南线要速记优先'));
    app.run(() => app.ws.createEvent(name: '指南线发布'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await switchTab(tester, '更多');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '指南线');
    await tester.pumpAndSettle();

    // 三条命中各来自一类实体，用"命中字段"区分（标题 / 内容 / 名称）
    expect(find.text('指南线要速记优先'), findsOneWidget);
    expect(find.text('指南线发布'), findsOneWidget);
    expect(find.textContaining('命中「标题」'), findsOneWidget);
    expect(find.textContaining('命中「内容」'), findsOneWidget);
    expect(find.textContaining('命中「名称」'), findsOneWidget);
  });

  testWidgets('归档区能取消归档并让内容回到主视图', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final project = app.ws.createProject(title: '会归档的项目');
    app.run(() => app.ws.setProjectArchived(project.id, true));
    expect(app.ws.liveProjects.where((p) => !p.archived).length, 0);

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await switchTab(tester, '更多');
    await tester.tap(find.text('归档区'));
    await tester.pumpAndSettle();
    expect(find.text('已归档 1'), findsOneWidget);
    expect(find.text('会归档的项目'), findsOneWidget);

    await tester.tap(find.text('取消归档'));
    await tester.pumpAndSettle();
    expect(app.ws.liveProjects.where((p) => !p.archived).length, 1);
  });

  testWidgets('逾期任务会在启动时提醒，并能一键跳到到期页', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '带逾期任务的事件');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '早就该做的事',
          dueAt: '2020-01-01',
        ));
    app.run(() => app.ws.createTask(eventId: event.id, title: '没有到期日的事'));

    expect(app.overdueCount, 1, reason: '只算逾期的，不算没设到期日的');
    expect(app.dueCount, 1);

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 启动就看得见（设计上不做推送唤醒，这是唯一的提醒入口）
    expect(find.text('有 1 条任务已逾期'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('1')),
      findsOneWidget,
      reason: '「更多」页签上应该有逾期角标',
    );

    await tester.tap(find.text('有 1 条任务已逾期'));
    await tester.pumpAndSettle();
    expect(find.text('早就该做的事'), findsOneWidget);
    expect(find.text('没有到期日的事'), findsNothing, reason: '没设到期日的不该出现在到期页');
  });

  testWidgets('已完成的任务默认折叠下级，点一下能展开', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '折叠演示');
    final mainTask = app.ws.createTask(eventId: event.id, title: '主任务');
    final subtask = app.ws.createTask(
      eventId: event.id,
      title: '子任务可见性',
      parentTaskId: mainTask.id,
      type: TaskType.subtask,
    );
    // 子任务先完成，父任务才允许被标记完成
    app.run(() => app.ws.setTaskStatus(subtask.id, NodeStatus.done));
    app.run(() => app.ws.setTaskStatus(mainTask.id, NodeStatus.done));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await switchTab(tester, '事件');
    await tester.tap(find.text('折叠演示'));
    await tester.pumpAndSettle();

    expect(find.text('已折叠 1 个下级'), findsOneWidget, reason: '已完成的任务应默认折叠下级');
    expect(find.text('子任务可见性'), findsNothing, reason: '折叠状态下级行不该被构建出来');

    await tester.tap(find.text('已折叠 1 个下级'));
    await tester.pumpAndSettle();
    expect(find.text('子任务可见性'), findsOneWidget, reason: '点开后要能看到下级');
  });

  testWidgets('深色模式 + 1.6 倍字体下四个 Tab 不溢出', (tester) async {
    // 360×780 逻辑像素（常见手机），字体放大到 1.6 倍 —— 布局溢出会直接让测试失败
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final project = app.ws.createProject(title: '一个名字相当长的项目名');
    app.run(() => app.ws.updateProject(project.id, purpose: '一句相当长的目的说明，用来撑满一行'));
    final event = app.ws.createEvent(name: '一个名字相当长的事件名');
    final task = app.ws.createTask(eventId: event.id, title: '一条名字相当长的主线任务');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '子任务',
          parentTaskId: task.id,
          type: TaskType.subtask,
        ));
    app.run(() => app.ws.captureInspiration('一条比较长的灵感内容，用来检验放大字体后会不会挤爆布局'));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();

    await switchTab(tester, '项目');
    await switchTab(tester, '事件');

    // 进任务线并打开任务动作面板（项目最多，是最容易溢出的地方）
    await tester.tap(find.text('一个名字相当长的事件名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一条名字相当长的主线任务'));
    await tester.pumpAndSettle();
    // 「新建并列任务」已删除（并列走向改由「接后续任务…」表达），改断言仍在的项
    expect(find.text('接后续任务…'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // 点遮罩关掉面板
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await switchTab(tester, '更多');
    await tester.tap(find.text('全部任务'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
  });
}
