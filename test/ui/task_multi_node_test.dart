import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';

/// 「新建后续节点」：删掉「新建并列任务」之后，用户反馈"没法创建多节点任务了"。
/// 这条路径要保证**一次点击就能铺出分叉**。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_newnode_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('从折线图标的菜单新建后续节点：真的接出一条边，并进入改名', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '铺节点');
    final first = app.ws.createTask(eventId: event.id, title: '节点一');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('铺节点'));
    await tester.pumpAndSettle();

    // 折线图标那个菜单
    final flowMenu = find.byWidgetPredicate(
      (w) => w is PopupMenuButton<String> && w.tooltip == '族内动作',
    );
    expect(flowMenu, findsOneWidget);
    await tester.tap(flowMenu);
    await tester.pumpAndSettle();
    expect(find.text('新建后续节点'), findsOneWidget);

    await tester.tap(find.text('新建后续节点'));
    await tester.pumpAndSettle();

    // 数据上：多了一个节点，而且是从「节点一」接出去的
    final tasks = app.ws.liveTasks.toList();
    expect(tasks.length, 2, reason: '应当多出一条任务（多节点）');
    final created = tasks.firstWhere((t) => t.id != first.id);
    final source = app.ws.findTask(first.id)!;
    expect(
      source.nextIds,
      contains(created.id),
      reason: '新节点必须真的接在这条之后，否则不是"多节点"',
    );

    // 界面上：进入改名态（与新建子任务的手感一致）
    expect(find.byType(TextField), findsWidgets, reason: '建完应当直接进入改名');
  });
}
