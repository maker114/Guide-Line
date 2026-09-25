import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';

/// 灵感页的新接线（灵感整理第 2、6、9 条）：
///   · 点一条 → 动作面板里有「编辑内容」，改完落盘；
///   · 长按任一条进入多选，批量分配 / 丢弃；
///   · 项目详情页的待处理灵感可以直接点进合并编辑器（不必绕回灵感页）。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_insp_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  testWidgets('点灵感 → 编辑内容 → 改完真的落盘', (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('原来的灵感内容'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('原来的灵感内容'));
    await tester.pumpAndSettle();
    expect(find.text('编辑内容'), findsOneWidget, reason: '动作面板里要有编辑入口');

    await tester.tap(find.text('编辑内容'));
    await tester.pumpAndSettle();

    // 编辑态是**页内直编**：此时有两个输入框 —— 上面的速记框（空）和
    // 这条灵感的编辑行（预填原值），要改的是后者。
    expect(find.byType(TextField), findsNWidgets(2));
    final field = find.byType(TextField).last;
    await tester.enterText(field, '改过之后的灵感内容');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      app.ws.liveInspirations.single.text,
      '改过之后的灵感内容',
      reason: '改完要真的写进数据',
    );
  });

  testWidgets('长按进入多选，批量分配一次改完所有选中项', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标项目');
    app.run(() => app.ws.captureInspiration('灵感甲'));
    app.run(() => app.ws.captureInspiration('灵感乙'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 长按第一条 → 进入多选（"已选 n 条"在多选条和标题行各出现一次）
    await tester.longPress(find.text('灵感甲'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsWidgets);
    // 多选模式：每条前面一个勾选框，**外加动作条里的「全选」**那个
    expect(find.byType(Checkbox), findsNWidgets(3));

    // 再点第二条 → 选中两条
    await tester.tap(find.text('灵感乙'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsWidgets);

    // 批量分配
    await tester.tap(find.byIcon(Icons.drive_file_move_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标项目').last);
    await tester.pumpAndSettle();

    for (final inspiration in app.ws.liveInspirations) {
      expect(inspiration.projectId, project.id, reason: '两条都该被分配到目标项目');
    }
  });

  testWidgets('多选批量丢弃：一次丢两条，且退出多选', (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('待丢甲'));
    app.run(() => app.ws.captureInspiration('待丢乙'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('待丢甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待丢乙'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pumpAndSettle();

    expect(app.ws.inspirationInbox, isEmpty, reason: '两条都该被丢弃');
    expect(app.ws.archiveZone.discardedInspirations.length, 2);
    expect(find.text('已选 1 条'), findsNothing, reason: '批量动作完要退出多选');
  });

  testWidgets('多选里有「全选」：一次选中当前可见的全部', (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('甲'));
    app.run(() => app.ws.captureInspiration('乙'));
    app.run(() => app.ws.captureInspiration('丙'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsWidgets, reason: '进多选默认选中第一条');

    // 动作条里的「全选」勾选框是那一排里最靠左的那个
    final selectAll = find.byType(Checkbox).first;
    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsWidgets, reason: '全选应当把可见的都选上');

    // 再点一次 = 取消全选
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsWidgets);
  });

  testWidgets('「多选」按钮也能进多选（不只有长按这一条路）', (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('一条灵感'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsWidgets, reason: '点「多选」默认选中第一条，省一次点击');
  });

  testWidgets('项目详情页的待处理灵感可以直接点进合并编辑器', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目甲');
    app.run(() => app.ws.captureInspiration('这条灵感要合并', projectId: project.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目甲').first);
    await tester.pumpAndSettle();

    // 灵感区在页面靠下（前面还有标识色等字段），`ListView` 是懒构建的，
    // 所以"待处理灵感"这块**在滚动到之前根本没被建出来** —— 必须先滚再看。
    await tester.scrollUntilVisible(
      find.text('这条灵感要合并'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('待处理灵感 1'), findsOneWidget);
    await tester.ensureVisible(find.text('这条灵感要合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这条灵感要合并'));
    await tester.pumpAndSettle();

    // 进了合并编辑器：标题带项目名，且有「追加原文」
    expect(find.textContaining('合并进「项目甲」'), findsOneWidget);
    expect(find.text('追加原文'), findsOneWidget);
  });

  testWidgets('合并编辑器「追加原文」把原文原样接到实现末尾', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目乙');
    app.run(() => app.ws.updateProject(project.id, implementation: '已有的一行'));
    app.run(() => app.ws.captureInspiration('灵感原文', projectId: project.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目乙').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('灵感原文'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('灵感原文'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('灵感原文'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('追加原文'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first,
    );
    expect(
      field.controller!.text,
      '已有的一行\n灵感原文',
      reason: '追加是"原文作为新的一行"，不改写也不润色',
    );
  });
}
