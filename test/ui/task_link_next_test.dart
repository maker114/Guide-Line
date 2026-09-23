import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';

/// 「接后续任务… / 断开后续…」这条界面的**接线测试**。
///
/// 规则层（`test/core/task_flow_rules_test.dart`）只保证图算得对；
/// 这里保证用户真的能把分叉 / 合流点出来 —— 尤其是
/// **固化隐式链**这一步有没有把原来的顺序弄丢（那是纯 TDD 抓不到的接线问题）。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guideline_link_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 底部面板里的文字。页面本身也有一份同名任务，直接 `find.text` 会同时命中两处。
  Finder inSheet(String text) =>
      find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

  Future<void> openEvent(WidgetTester tester, String name) async {
    await tester.tap(
      find.descendant(of: find.byType(NavigationBar), matching: find.text('事件')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  /// 点开任务动作面板并选一项。
  Future<void> chooseAction(WidgetTester tester, String task, String action) async {
    await tester.tap(find.text(task));
    await tester.pumpAndSettle();
    await tester.tap(inSheet(action));
    await tester.pumpAndSettle();
  }

  /// 「新建一个后续任务」建完会直接进入原地改名，这里把新名字敲进去并提交。
  Future<void> finishRename(WidgetTester tester, String text) async {
    final focused = find.byWidgetPredicate(
      (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
      description: '正在改名的输入框',
    );
    expect(focused, findsOneWidget, reason: '新建之后应当直接进入改名');
    await tester.enterText(focused, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('「接后续任务…」新建一条后续：原来那条链没丢，且变成分叉', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '接线演示');
    final first = app.ws.createTask(eventId: event.id, title: '主线甲');
    final second = app.ws.createTask(eventId: event.id, title: '主线乙');
    expect(app.ws.findTask(first.id)!.nextIds, isEmpty,
        reason: '一开始是隐式链（靠 order），还没有显式边');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await openEvent(tester, '接线演示');
    expect(find.text('主线甲'), findsOneWidget);
    expect(find.text('主线乙'), findsOneWidget);

    await chooseAction(tester, '主线甲', '接后续任务…');
    expect(find.text('接在「主线甲」之后'), findsOneWidget);
    await tester.tap(inSheet('新建一个后续任务'));
    await tester.pumpAndSettle();
    await finishRename(tester, '支路丙');

    // 先断数据：新任务接在甲之后，而且甲→乙这条边还在
    final updated = app.ws.findTask(first.id)!;
    expect(updated.nextIds.length, 2, reason: '甲同时接向乙和丙 —— 这就是分叉');
    expect(updated.nextIds.contains(second.id), isTrue,
        reason: '固化隐式链时不能把原来的甲→乙弄丢');
    final branchId = updated.nextIds.firstWhere((id) => id != second.id);
    expect(app.ws.findTask(branchId)!.title, '支路丙');
    expect(app.ws.findTask(second.id)!.nextIds, isEmpty, reason: '乙仍然是链尾');

    // 再断界面
    expect(find.textContaining('分出 2 条支路'), findsOneWidget);
    expect(find.textContaining('支路 1 / 2'), findsOneWidget);
    expect(find.textContaining('支路 2 / 2'), findsOneWidget);
    expect(find.text('支路丙'), findsOneWidget);
    expect(find.text('主线乙'), findsOneWidget);
  });

  testWidgets('把上游接到更后面的任务上：两条支路在同一个节点汇合', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '合流演示');
    final a = app.ws.createTask(eventId: event.id, title: '主线甲');
    app.ws.createTask(eventId: event.id, title: '主线乙');
    // 这三条按 order 连成隐式链 甲→乙→丙
    app.ws.createTask(eventId: event.id, title: '主线丙');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await openEvent(tester, '合流演示');

    // 甲直接接到丙：于是 甲→乙→丙 与 甲→丙 两条支路都在丙汇合
    await chooseAction(tester, '主线甲', '接后续任务…');
    await tester.tap(inSheet('主线丙'));
    await tester.pumpAndSettle();

    expect(app.ws.findTask(a.id)!.nextIds.length, 2);
    expect(find.textContaining('2 条支路在此汇合'), findsOneWidget);
    expect(find.textContaining('分出 2 条支路'), findsOneWidget);
    // 汇合点只渲染一次，不是两条支路各画一遍
    expect(find.text('主线丙'), findsOneWidget);
  });

  testWidgets('「断开后续…」只在真有后续时出现，断掉之后分叉消失', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '断开演示');
    final a = app.ws.createTask(eventId: event.id, title: '主线甲');
    final b = app.ws.createTask(eventId: event.id, title: '主线乙');
    final c = app.ws.createTask(eventId: event.id, title: '主线丙');
    // 先由规则层把 甲→{乙,丙} 建好，界面上只验"断开"这一半
    app.run(() => app.ws.setTaskNext(a.id, <String>[b.id, c.id]));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await openEvent(tester, '断开演示');
    expect(find.textContaining('分出 2 条支路'), findsOneWidget);

    await chooseAction(tester, '主线甲', '断开后续…');
    expect(find.text('「主线甲」现在接向'), findsOneWidget);
    await tester.tap(inSheet('主线丙'));
    await tester.pumpAndSettle();

    expect(app.ws.findTask(a.id)!.nextIds, <String>[b.id]);
    expect(find.textContaining('分出 2 条支路'), findsNothing,
        reason: '只剩一条后续就不再是分叉');
    expect(find.text('主线丙'), findsOneWidget, reason: '断开的节点不能从界面上消失');

    // 后续全断光之后，「断开后续…」这一项就不该再出现
    await chooseAction(tester, '主线甲', '断开后续…');
    await tester.tap(inSheet('主线乙'));
    await tester.pumpAndSettle();
    expect(app.ws.findTask(a.id)!.nextIds, isEmpty);

    await tester.tap(find.text('主线甲'));
    await tester.pumpAndSettle();
    expect(inSheet('断开后续…'), findsNothing);
    expect(inSheet('接后续任务…'), findsOneWidget);
  });
}
