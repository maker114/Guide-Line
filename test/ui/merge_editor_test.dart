import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/inspiration/merge_editor_page.dart';

import 'scroll_finders.dart';

/// 合并编辑器的**三种选择**（实机反馈）：
///   1. 编辑框里是**当前的「实现计划」**，照着灵感手改完点「保存」→ 替换正文；
///   2. 「追加原文」把灵感原文**另起一行**接到正文末尾（仍要点保存）；
///   3. 「作为清单条目」不碰正文，直接把它追加成清单的新一条。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_merge_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  /// 从项目页点进详情，再点开那条待处理灵感的合并编辑器。
  Future<void> openMergeEditor(
    WidgetTester tester,
    AppController app,
    String projectTitle,
    String inspirationText,
  ) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(projectTitle).first);
    await tester.pumpAndSettle();
    // 灵感区在页面靠下，`ListView` 懒构建 —— 先滚出来再点
    await tester.scrollUntilVisible(
      find.text(inspirationText),
      120,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(inspirationText));
    await tester.pumpAndSettle();
    await tester.tap(find.text(inspirationText));
    await tester.pumpAndSettle();
  }

  /// 编辑框（合并编辑器里的正文框）的当前文本。
  String editorText(WidgetTester tester) {
    final field = tester.widget<TextField>(
      find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first,
    );
    return field.controller!.text;
  }

  testWidgets('一进来就显示当前的「实现计划」', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目甲');
    app.run(() => app.ws.updateProject(project.id, implementation: '已有的计划\n第二行'));
    app.run(() => app.ws.captureInspiration('这条灵感要合并', projectId: project.id));

    await openMergeEditor(tester, app, '项目甲', '这条灵感要合并');

    expect(find.textContaining('合并进「项目甲」'), findsOneWidget);
    expect(find.text('实现计划（可编辑）'), findsOneWidget);
    expect(editorText(tester), '已有的计划\n第二行');
  });

  testWidgets('选择二「追加原文」：原文另起一行接到末尾，保存后才写回', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目乙');
    app.run(() => app.ws.updateProject(project.id, implementation: '已有的一行'));
    app.run(() => app.ws.captureInspiration('灵感原文', projectId: project.id));

    await openMergeEditor(tester, app, '项目乙', '灵感原文');
    await tester.tap(find.text('追加原文'));
    await tester.pumpAndSettle();

    expect(
      editorText(tester),
      '已有的一行\n灵感原文',
      reason: '追加是"原文作为新的一行"，不改写也不润色',
    );
    expect(
      app.ws.findProject(project.id)!.implementation,
      '已有的一行',
      reason: '只改编辑框，没点保存就不该写盘',
    );

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.implementation, '已有的一行\n灵感原文');
    expect(app.ws.findProject(project.id)!.items, isEmpty, reason: '这条不动清单');
    expect(app.ws.inspirationInbox, isEmpty);
    expect(app.ws.archiveZone.mergedInspirations.length, 1);
  });

  testWidgets('选择三「作为清单条目」：正文不动，清单后面多一条', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目丙');
    app.run(() => app.ws.updateProject(project.id, implementation: '已有的计划'));
    app.run(() => app.ws.addProjectItem(project.id, '原来就有的条目'));
    app.run(() => app.ws.captureInspiration('灵感原文', projectId: project.id));

    await openMergeEditor(tester, app, '项目丙', '灵感原文');
    await tester.tap(find.text('作为清单条目'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(
      reloaded.items.map((i) => i.text),
      <String>['原来就有的条目', '灵感原文'],
      reason: '作为清单的一项**放在清单后面**',
    );
    expect(reloaded.implementation, '已有的计划', reason: '这一条不碰「实现计划」');
    expect(app.ws.inspirationInbox, isEmpty);
    expect(app.ws.archiveZone.mergedInspirations.length, 1);
    // 回到详情页就能在清单里看到它
    expect(find.text('灵感原文'), findsOneWidget);
  });

  testWidgets('正文空着点「保存」不会把「实现计划」清没', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目丁');
    app.run(() => app.ws.updateProject(project.id, implementation: '不能丢的一段'));
    final inspiration = app.ws.captureInspiration('灵感原文', projectId: project.id);

    await openMergeEditor(tester, app, '项目丁', '灵感原文');
    await tester.enterText(
      find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first,
      '   ',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 留在这一页并给提示，不 pop、不写盘、也不把灵感标成已合并
    expect(find.textContaining('正文不能是空的'), findsOneWidget);
    expect(app.ws.findProject(project.id)!.implementation, '不能丢的一段');
    expect(app.ws.findInspiration(inspiration.id)!.isPending, isTrue);
  });

  testWidgets('深色 + 1.6 倍字体、窄屏下这一页不溢出', (tester) async {
    // 360×780 逻辑像素（常见手机），字体放大到 1.6 倍 —— 布局溢出会直接让测试失败
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await boot();
    final project = app.ws.createProject(title: '一个名字相当长的项目名');
    app.run(() => app.ws.updateProject(project.id, implementation: '一段相当长的正文，用来撑满编辑框'));
    final inspiration = app.ws.captureInspiration(
      '一条比较长的灵感内容，用来检验放大字体后会不会挤爆布局',
      projectId: project.id,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: MergeEditorPage(
          project: app.ws.findProject(project.id)!,
          inspiration: inspiration,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 三个选择都在，且没有溢出（溢出会以 FlutterError 的形式让这条用例失败）
    expect(find.text('实现计划（可编辑）'), findsOneWidget);
    expect(find.text('追加原文'), findsOneWidget);
    expect(find.text('作为清单条目'), findsOneWidget);
  });
}
