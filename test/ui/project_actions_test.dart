import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/projects/project_actions.dart';

/// 项目删除确认框的文案口径（Q6）：**灵感与"项目 / 事件 / 任务"分开说**。
///
/// 灵感是唯一不进回收站的实体（《定义与边界》§8）—— 合成一句"全部可在回收站
/// 恢复"，用户就会以为灵感也躺在回收站里等着它，删完才发现找不回来。
/// 另外"未处理灵感"按契约口径**包含已经丢弃、还没恢复的那些**（只看是否已合并），
/// 这一点也必须写进那句话里。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_project_actions_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  /// 直接把 `deleteProjectAction` 挂在一个按钮上（确认框是它的产物）。
  Future<void> openDeleteDialog(
    WidgetTester tester,
    AppController app,
    String projectId,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => deleteProjectAction(context, app, projectId),
              child: const Text('删除项目'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('删除项目'));
    await tester.pumpAndSettle();
  }

  testWidgets('删项目确认框：灵感单独一句（永久删除、不进回收站，含已丢弃的）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '要删的项目');
    app.ws.createProject(title: '子项目', parentId: project.id);
    // 两条"未处理"灵感：一条正常、一条已丢弃但没恢复（契约口径里都算未处理）
    final pending = app.ws.captureInspiration('正常的一条', projectId: project.id);
    final discarded = app.ws.captureInspiration('丢弃过的一条', projectId: project.id);
    app.run(() => app.ws.discardInspiration(discarded.id));
    // 一条已合并的：它退回「未分配」，不进"永久删除"那一句
    final merged = app.ws.captureInspiration('合并过的一条', projectId: project.id);
    app.run(() => app.ws.mergeInspiration(
          inspirationId: merged.id,
          projectId: project.id,
          newImplementation: '写进项目的正文',
        ));
    expect(app.ws.findInspiration(pending.id)!.isPending, isTrue);

    await openDeleteDialog(tester, app, project.id);

    expect(find.text('删除项目'), findsWidgets);
    expect(
      find.textContaining('这 2 条未处理灵感会被永久删除，包含已经丢弃但尚未恢复的条目'),
      findsOneWidget,
      reason: '丢弃过的那条同样是"未处理"，也留不下来',
    );
    expect(find.textContaining('不进回收站'), findsOneWidget);
    expect(
      find.textContaining('1 条已合并灵感会退回「未分配」'),
      findsOneWidget,
    );
    // 项目 / 事件 / 任务那一侧仍如实说"能恢复、30 天后自动清除"
    expect(
      find.textContaining('项目 / 事件 / 任务可在「更多 → 归档区 → 回收站」恢复，30 天后自动清除'),
      findsOneWidget,
    );
    expect(
      find.textContaining('全部可在「更多 → 归档区 → 回收站」恢复'),
      findsNothing,
      reason: '合成一句"全部可恢复"会把灵感也包进去 —— 那是假话',
    );

    // 取消掉，别真的删（这条用例只审文案）
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('没有灵感的项目：不出现"永久删除"那一句（不吓人）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '干净的项目');

    await openDeleteDialog(tester, app, project.id);

    expect(find.textContaining('永久删除'), findsNothing);
    expect(find.textContaining('不进回收站'), findsNothing);
    expect(
      find.textContaining('可在「更多 → 归档区 → 回收站」恢复，30 天后自动清除'),
      findsOneWidget,
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
