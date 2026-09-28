import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/animated_collapse.dart';
import 'package:guideline/ui/common/inline_editor.dart';

/// 2026-09-28 第六批实机反馈里"看得见的那几件"：
///   · 灵感箱空态每启动一次换一句；
///   · 事件页的到期日只在行内按钮上，动作面板里不再有它；
///   · 展开 / 收起与输入框展开都有动画。
///
/// 动画本身没法用断言"好不好看"（那是截图的事），但可以钉住**接线**：
/// 该有动画壳的地方真的有，且它在展开 / 收起时 Presence 正确。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_polish');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('灵感箱文案：每启动一次重抽（种子会变）', () async {
    final first = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final seedA = first.prefs.emptyBoxSeed;
    expect(seedA, isNotNull, reason: '启动时抽一次并落进偏好');

    // 同一个实例内不再变（界面只读它）
    expect(first.prefs.emptyBoxSeed, seedA);

    // 等一微秒，保证时间种子不同
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final second = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(
      second.prefs.emptyBoxSeed,
      isNot(seedA),
      reason: '每次启动都要重抽 —— 上一版只在没有种子时抽，第二次开 App 还是同一句',
    );
  });

  testWidgets('事件页：到期日只在行内按钮上，动作面板里没有那一项', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一件事');
    final task = app.ws.createTask(eventId: event.id, title: '一条主线');
    app.run(() => app.ws.updateTask(task.id, dueAt: '2099-05-01'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一件事'));
    await tester.pumpAndSettle();

    // 行内那颗按钮还在（点它开日期面板）
    expect(find.byIcon(Icons.event_available_outlined), findsOneWidget);

    // 点任务行 → 动作面板：**没有**设 / 改到期日
    await tester.tap(find.text('一条主线'));
    await tester.pumpAndSettle();
    expect(find.text('改到期日'), findsNothing, reason: '已按实机反馈从下拉菜单里删掉');
    expect(find.text('设到期日'), findsNothing);
    expect(find.text('新建子任务'), findsOneWidget, reason: '面板本身还在');

    // 关掉面板，点行内按钮 → 日期面板照常出来
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.event_available_outlined));
    await tester.pumpAndSettle();
    expect(find.text('清除日期'), findsOneWidget, reason: '行内按钮才是日期的落点');
  });

  testWidgets('事件页：展开子任务时挂了动画壳', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一件事');
    final parent = app.ws.createTask(eventId: event.id, title: '主线');
    app.ws.createTask(
      eventId: event.id,
      title: '子任务',
      parentTaskId: parent.id,
      type: TaskType.subtask,
    );

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一件事'));
    await tester.pumpAndSettle();

    expect(find.byType(AnimatedCollapse), findsWidgets, reason: '子任务列表要有展开动画');
  });

  testWidgets('输入框：展开时挂了动画壳（AnimatedComposer 那一层）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.ws.createProject(title: '一个目标');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一个目标').first);
    await tester.pumpAndSettle();

    // `InlineComposer` 外面那层 `AnimatedSize` 就是输入框的展开动画
    expect(
      find.descendant(
        of: find.byType(InlineComposer),
        matching: find.byType(AnimatedSize),
      ),
      findsWidgets,
      reason: '输入框展开要有动画（实机反馈：输入框的展开要流畅）',
    );
  });
}
