import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/inspiration/merge_editor_page.dart';

import 'scroll_finders.dart';

/// 合并编辑器的**三种选择**（实机反馈）：
///   1. 编辑框里是**当前的「如何解决」**，照着灵感手改完点「保存」→ 替换正文；
///   2. 「追加原文」把灵感原文**另起一行**接到正文末尾（仍要点保存）；
///   3. 「作为清单条目」不碰正文，直接把它追加成清单的新一条。
///
/// 另外守住 Q2 的一条边界：**落点只能是目标** —— 给分类打开这一页时，
/// 三种选择一个都不给，只说明"分类不装灵感"。
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

  testWidgets('一进来就显示当前的「如何解决」', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目甲');
    app.run(() => app.ws.updateProject(project.id, implementation: '已有的计划\n第二行'));
    app.run(() => app.ws.captureInspiration('这条灵感要合并', projectId: project.id));

    await openMergeEditor(tester, app, '项目甲', '这条灵感要合并');

    expect(find.textContaining('合并进「项目甲」'), findsOneWidget);
    expect(find.text('如何解决（可编辑）'), findsOneWidget);
    expect(find.text('实现计划（可编辑）'), findsNothing, reason: 'Q4：字段改称「如何解决」');
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
    expect(reloaded.implementation, '已有的计划', reason: '这一条不碰「如何解决」');
    expect(app.ws.inspirationInbox, isEmpty);
    expect(app.ws.archiveZone.mergedInspirations.length, 1);
    // 回到详情页就能在清单里看到它
    expect(find.text('灵感原文'), findsOneWidget);
  });

  testWidgets('正文空着点「保存」不会把「如何解决」清没', (tester) async {
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
    final message = find.textContaining('正文不能是空的');
    expect(message, findsOneWidget);
    // 报错吐司必须自己给文字色：底色是浅色的 errorContainer，默认文字色
    // （inverseOnSurface）在浅色主题下近乎纯白，压上去等于看不见。
    // 这条原来是靠"项目状态被规则拦下"那条用例守的；项目没有完成态之后（Q1），
    // 这里换成了同一套 showToast 的另一条错误路径。
    final scheme = Theme.of(tester.element(find.text('保存'))).colorScheme;
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.backgroundColor, scheme.errorContainer);
    expect(
      tester.widget<Text>(message).style?.color,
      scheme.onErrorContainer,
      reason: '浅色底上的默认文字色近乎纯白，得显式换成深色的 onErrorContainer',
    );
    expect(app.ws.findProject(project.id)!.implementation, '不能丢的一段');
    expect(app.ws.findInspiration(inspiration.id)!.isPending, isTrue);
  });

  testWidgets('正文一个字没改就点「保存」：不算合并（Q8）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目戊');
    app.run(() => app.ws.updateProject(project.id, implementation: '原封不动的计划'));
    final inspiration = app.ws.captureInspiration('这条灵感还没写进去', projectId: project.id);

    await openMergeEditor(tester, app, '项目戊', '这条灵感还没写进去');

    // 一进来编辑框就是当前正文，直接点保存 —— 什么都没发生
    expect(editorText(tester), '原封不动的计划');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('正文没有变化'),
      findsOneWidget,
      reason: '提示要说清"还没写进项目"，并点明两个能用的动作',
    );
    expect(
      find.textContaining('「追加原文」或「作为清单条目」'),
      findsOneWidget,
    );
    // 留在这一页、不写盘、灵感仍是待处理 —— 不能"报成功却什么都没多"
    expect(find.text('如何解决（可编辑）'), findsOneWidget);
    expect(app.ws.findProject(project.id)!.implementation, '原封不动的计划');
    expect(app.ws.findInspiration(inspiration.id)!.isPending, isTrue);
    expect(app.ws.archiveZone.mergedInspirations, isEmpty);
  });

  testWidgets('改过（哪怕只多一个字）就照常保存', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目己');
    app.run(() => app.ws.updateProject(project.id, implementation: '原封不动的计划'));
    app.run(() => app.ws.captureInspiration('这条灵感要合并', projectId: project.id));

    await openMergeEditor(tester, app, '项目己', '这条灵感要合并');
    await tester.enterText(
      find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first,
      '原封不动的计划\n灵感写进来了',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.implementation, '原封不动的计划\n灵感写进来了');
    expect(app.ws.inspirationInbox, isEmpty);
  });

  testWidgets('落盘那一步也挡"正文没变"：applyMergeResult 不动数据', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目庚');
    app.run(() => app.ws.updateProject(project.id, implementation: '原封不动的计划'));
    final inspiration = app.ws.captureInspiration('这条灵感没写进去', projectId: project.id);
    final snapshot = app.ws.findProject(project.id)!;

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () => applyMergeResult(
          context,
          app,
          snapshot,
          inspiration,
          const MergeResult.intoImplementation('原封不动的计划'),
        ),
        child: const Text('落盘'),
      ),
    ))));
    await tester.tap(find.text('落盘'));
    await tester.pumpAndSettle();

    expect(find.textContaining('正文没有变化'), findsOneWidget);
    expect(app.ws.findInspiration(inspiration.id)!.isPending, isTrue, reason: '灵感不该被标成已合并');
    expect(app.ws.findProject(project.id)!.updatedAt, snapshot.updatedAt, reason: '项目一个字都没动');
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
    expect(find.text('如何解决（可编辑）'), findsOneWidget);
    expect(find.text('追加原文'), findsOneWidget);
    expect(find.text('作为清单条目'), findsOneWidget);
  });

  testWidgets('多选合并：原文按顺序列出来（默认展开），「追加原文」各占一行（Q37）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目辛');
    app.run(() => app.ws.updateProject(project.id, implementation: '已有的一行'));
    final first = app.ws.captureInspiration('第一条原文');
    final second = app.ws.captureInspiration('第二条原文');

    await tester.pumpWidget(
      MaterialApp(
        home: MergeEditorPage.many(
          project: app.ws.findProject(project.id)!,
          inspirations: <Inspiration>[first, second],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // "这次并的是哪几条"：条数写进标题、原文按顺序列出来，多条默认展开
    expect(find.text('灵感原文（参考 · 2 条）'), findsOneWidget);
    expect(find.text('第一条原文'), findsOneWidget);
    expect(find.text('第二条原文'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('第一条原文')).dy,
      lessThan(tester.getTopLeft(find.text('第二条原文')).dy),
      reason: '列出的顺序就是落进项目的顺序',
    );

    await tester.tap(find.text('追加原文'));
    await tester.pumpAndSettle();

    expect(editorText(tester), '已有的一行\n第一条原文\n第二条原文');
    expect(
      app.ws.findProject(project.id)!.implementation,
      '已有的一行',
      reason: '只改编辑框，没点保存就不该写盘',
    );
  });

  testWidgets('多条 + 深色 + 1.6 倍字体、窄屏下这一页也不溢出（Q37）', (tester) async {
    // 多条一起并时「灵感原文（参考）」默认展开（多一块固定高度），最容易挤爆布局
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await boot();
    final project = app.ws.createProject(title: '一个名字相当长的项目名');
    app.run(() => app.ws.updateProject(project.id, implementation: '一段相当长的正文，用来撑满编辑框'));
    final inspirations = <Inspiration>[
      app.ws.captureInspiration('一条比较长的灵感内容，用来检验放大字体后会不会挤爆布局', projectId: project.id),
      app.ws.captureInspiration('另一条同样很长的灵感内容，多条一起并时参考面板默认是展开的', projectId: project.id),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: MergeEditorPage.many(
          project: app.ws.findProject(project.id)!,
          inspirations: inspirations,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('如何解决（可编辑）'), findsOneWidget);
    expect(find.text('追加原文'), findsOneWidget);
    expect(find.text('作为清单条目'), findsOneWidget);
    expect(find.text('灵感原文（参考 · 2 条）'), findsOneWidget);
  });

  testWidgets('分类不装灵感：给分类打开这一页时不给任何合并动作，只说明原因', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    app.ws.createProject(title: '发布 v1', parentId: category.id);
    final inspiration = app.ws.captureInspiration('一条灵感', projectId: category.id);

    await tester.pumpWidget(
      MaterialApp(
        home: MergeEditorPage(
          project: app.ws.findProject(category.id)!,
          inspiration: inspiration,
          isCategory: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('分类不装灵感，请选一个目标或先建一个目标'), findsOneWidget);
    expect(find.text('保存'), findsNothing, reason: '分类没有「如何解决」可写');
    expect(find.text('追加原文'), findsNothing);
    expect(find.text('作为清单条目'), findsNothing, reason: '分类也没有实现清单');
    // 原文还是要看得到：用户得知道自己手上这条是什么
    expect(find.text('灵感原文（参考）'), findsOneWidget);
  });

  testWidgets('落盘那一步也挡分类：applyMergeResult 不会把灵感并进分类', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    app.ws.createProject(title: '发布 v1', parentId: category.id);
    final inspiration = app.ws.captureInspiration('一条灵感', projectId: category.id);
    final snapshot = app.ws.findProject(category.id)!;

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () => applyMergeResult(
          context,
          app,
          snapshot,
          inspiration,
          const MergeResult.intoImplementation('不该写进去的一段'),
        ),
        child: const Text('落盘'),
      ),
    ))));
    await tester.tap(find.text('落盘'));
    await tester.pumpAndSettle();

    expect(find.text('分类不装灵感，请选一个目标或先建一个目标'), findsOneWidget);
    expect(app.ws.findProject(category.id)!.implementation, isEmpty);
    expect(app.ws.findInspiration(inspiration.id)!.isPending, isTrue, reason: '灵感不该被标成已合并');
  });
}
