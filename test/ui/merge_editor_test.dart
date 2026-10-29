import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/inspiration/merge_editor_page.dart';

import 'scroll_finders.dart';

/// 合并页（2026-10-29 重做）：**永远只作为清单被合并** ——
///   · 上半是项目**已有的清单**（只读、带完成态与进度）；
///   · 下半用主题色把「本次合并新增 N 条」与这次要并进来的每一条接在后面；
///   · 右上角「合并」交回按顺序的原文，由 `applyMergeResultFor` 一次落盘。
///
/// 另外守住 Q2 的一条边界：**落点只能是目标** —— 给分类打开这一页时，
/// 不给任何合并动作，只说明"分类不装灵感"。
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

  /// 从项目页点进详情，再点开那条待处理灵感的合并页。
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

  testWidgets('一进来就列出项目已有的清单：带进度，已完成的划线 + 灰', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目甲');
    app.run(() => app.ws.addProjectItem(project.id, '已经做完的一条'));
    app.run(() => app.ws.setProjectItemDone(
          project.id,
          app.ws.findProject(project.id)!.items.single.id,
          true,
        ));
    app.run(() => app.ws.addProjectItem(project.id, '还没做的一条'));
    app.run(() => app.ws.captureInspiration('这条灵感要合并', projectId: project.id));

    await openMergeEditor(tester, app, '项目甲', '这条灵感要合并');

    expect(find.textContaining('合并进「项目甲」'), findsOneWidget);
    expect(find.text('项目已有的清单 1/2'), findsOneWidget, reason: '并之前先知道这个项目已经做了多少');
    expect(find.text('已经做完的一条'), findsOneWidget);
    expect(find.text('还没做的一条'), findsOneWidget);

    final theme = Theme.of(tester.element(find.text('项目已有的清单 1/2')));
    final doneStyle = tester.widget<Text>(find.text('已经做完的一条')).style!;
    expect(doneStyle.decoration, TextDecoration.lineThrough, reason: '已完成保持划线');
    expect(doneStyle.color, theme.colorScheme.outline, reason: '已完成保持灰，与未完成分得开');
    final pendingStyle = tester.widget<Text>(find.text('还没做的一条')).style!;
    expect(pendingStyle.decoration, isNot(TextDecoration.lineThrough));
    expect(
      pendingStyle.color,
      theme.textTheme.bodyMedium?.color,
      reason: '未完成用正文色，不做额外强调',
    );

    // 这一页没有正文编辑器：合并只落清单
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('这次要并进来的内容用主题色接在已有清单后面（前面一个小 + 记号）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目乙');
    app.run(() => app.ws.addProjectItem(project.id, '原来就有的条目'));
    final inspiration = app.ws.captureInspiration('灵感原文', projectId: project.id);

    await tester.pumpWidget(MaterialApp(home: MergeEditorPage(
      project: app.ws.findProject(project.id)!,
      inspiration: inspiration,
    )));
    await tester.pumpAndSettle();

    final theme = Theme.of(tester.element(find.text('本次合并新增 1 条')));
    expect(
      tester.widget<Text>(find.text('本次合并新增 1 条')).style?.color,
      theme.colorScheme.primary,
      reason: '分隔标题用主题色画',
    );
    expect(
      tester.widget<Text>(find.text('灵感原文')).style?.color,
      theme.colorScheme.primary,
      reason: '新增的每一条也用主题色，与已有清单一眼分得开',
    );
    expect(find.text('+'), findsOneWidget, reason: '前面一个小 + 号：这几条是这次新加的');
    expect(
      tester.getTopLeft(find.text('灵感原文')).dy,
      greaterThan(tester.getTopLeft(find.text('原来就有的条目')).dy),
      reason: '新增内容接在已有清单后面',
    );
    expect(
      find.text('「恢复为待处理」只把灵感放回灵感箱，项目里的内容不会退回。'),
      findsOneWidget,
    );
  });

  testWidgets('空清单：写一句"还没有清单条目"，再做新增预览', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目丙');
    final inspiration = app.ws.captureInspiration('灵感原文', projectId: project.id);

    await tester.pumpWidget(MaterialApp(home: MergeEditorPage(
      project: app.ws.findProject(project.id)!,
      inspiration: inspiration,
    )));
    await tester.pumpAndSettle();

    expect(find.text('这个项目还没有清单条目。'), findsOneWidget);
    expect(find.text('本次合并新增 1 条'), findsOneWidget);
    expect(find.text('灵感原文'), findsOneWidget);
  });

  testWidgets('点「合并」：原文追加进清单，灵感进归档区「已合并」，正文一个字不动', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目丁');
    app.run(() => app.ws.updateProject(project.id, implementation: '原来写好的正文'));
    app.run(() => app.ws.addProjectItem(project.id, '原来就有的条目'));
    app.run(() => app.ws.captureInspiration('这条灵感要合并', projectId: project.id));

    await openMergeEditor(tester, app, '项目丁', '这条灵感要合并');
    expect(find.text('本次合并新增 1 条'), findsOneWidget);

    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(
      reloaded.items.map((i) => i.text),
      <String>['原来就有的条目', '这条灵感要合并'],
      reason: '合并 = 往清单后面追加一条',
    );
    expect(reloaded.implementation, '原来写好的正文', reason: '合并只落清单，不再改正文');
    expect(app.ws.inspirationInbox, isEmpty);
    expect(app.ws.archiveZone.mergedInspirations.length, 1);
    expect(find.textContaining('已追加到「项目丁」的清单'), findsOneWidget);
    // 回到详情页就能在清单里看到它
    expect(find.text('这条灵感要合并'), findsOneWidget);
  });

  testWidgets('多条合并：按列表顺序各成一条（一次 pop 带回全部原文）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目戊');
    app.run(() => app.ws.addProjectItem(project.id, '原来就有的条目'));
    final first = app.ws.captureInspiration('第一条原文');
    final second = app.ws.captureInspiration('第二条原文');

    late MergeResult? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<MergeResult>(
                  MaterialPageRoute<MergeResult>(
                    builder: (_) => MergeEditorPage.many(
                      project: app.ws.findProject(project.id)!,
                      inspirations: <Inspiration>[first, second],
                    ),
                  ),
                );
              },
              child: const Text('打开合并页'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开合并页'));
    await tester.pumpAndSettle();

    expect(find.text('本次合并新增 2 条'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('第一条原文')).dy,
      lessThan(tester.getTopLeft(find.text('第二条原文')).dy),
      reason: '预览顺序就是落盘顺序',
    );

    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();

    expect(popped!.itemTexts, <String>['第一条原文', '第二条原文']);
  });

  testWidgets('深色 + 1.6 倍字体、窄屏下这一页不溢出（清单长也只是往下滚）', (tester) async {
    // 360×780 逻辑像素（常见手机），字体放大到 1.6 倍 —— 布局溢出会直接让测试失败
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await boot();
    final project = app.ws.createProject(title: '一个名字相当长的项目名');
    for (var index = 0; index < 6; index += 1) {
      app.run(() => app.ws.addProjectItem(project.id, '第 $index 条已有的清单条目，长度也故意写长一点'));
    }
    final inspirations = <Inspiration>[
      app.ws.captureInspiration('一条比较长的灵感内容，用来检验放大字体后会不会挤爆布局', projectId: project.id),
      app.ws.captureInspiration('另一条同样很长的灵感内容，多条一起并时新增区也要撑得住', projectId: project.id),
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

    // 溢出会以 FlutterError 的形式让这条用例失败；这里再确认新增预览真的在
    expect(find.textContaining('本次合并新增 2 条'), findsOneWidget);
  });

  testWidgets('分类不装灵感：不给合并动作，只说明原因 + 已有清单预览', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    app.ws.createProject(title: '发布 v1', parentId: category.id);
    // 分类一般没有清单，这里塞一条是为了确认"已有清单预览"在分类页也能读
    app.run(() => app.ws.addProjectItem(category.id, '分类自己不装灵感'));
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
    expect(find.text('合并'), findsNothing, reason: '分类没有可合并的落点');
    expect(find.text('项目已有的清单 0/1'), findsOneWidget);
    expect(find.text('分类自己不装灵感'), findsOneWidget);
    expect(find.text('本次合并新增 1 条'), findsNothing, reason: '连动作都不给，也就不必预览新增');
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
          const MergeResult(itemTexts: <String>['不该写进去的一段']),
        ),
        child: const Text('落盘'),
      ),
    ))));
    await tester.tap(find.text('落盘'));
    await tester.pumpAndSettle();

    expect(find.text('分类不装灵感，请选一个目标或先建一个目标'), findsOneWidget);
    expect(app.ws.findProject(category.id)!.items, isEmpty);
    expect(app.ws.findInspiration(inspiration.id)!.isPending, isTrue, reason: '灵感不该被标成已合并');
  });
}
