import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';

/// 「收起 / 展开分类时会莫名弹出输入框」的复现。
///
/// 现象：正在改名的那一行**被折叠收走**之后再展开，输入框与键盘会**自己**
/// 又弹出来 —— 用户那边看到的就是"我只是收了个下级，怎么自己跳出输入框"。
///
/// 机制（`lib/ui/common/inline_editor.dart`）：`InlineTextField` 的编辑态由
/// 父级记着（这里是 `EventDetailPage._renamingTaskId`），而结束编辑只有
/// `_commit` / `_cancel` 两条路会回调 `onEditClosed`；**`dispose()` 不回调**。
/// 于是"编辑中的行被移出树"会留下父级的改名 id 非空，行再出现时
/// `autofocus: true` 直接把它重新推进编辑态。
///
/// 这条用例钉的就是"折叠往返之后不该有任何输入框"。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_stale_rename');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 开一个「事件 → 主线节点 → 子任务」并进到事件详情页。
  Future<AppController> openEvent(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '折叠演示');
    final parent = app.ws.createTask(eventId: event.id, title: '主线节点');
    app.ws.createTask(
      eventId: event.id,
      title: '子任务甲',
      parentTaskId: parent.id,
      type: TaskType.subtask,
    );

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('折叠演示'));
    await tester.pumpAndSettle();
    return app;
  }

  /// 点某一行 → 动作面板里选一项。
  Future<void> chooseAction(
    WidgetTester tester,
    String rowText,
    String actionLabel,
  ) async {
    await tester.tap(find.text(rowText));
    await tester.pumpAndSettle();
    await tester.tap(find.text(actionLabel));
    await tester.pumpAndSettle();
  }

  testWidgets('子任务正在改名时收起主线节点，再展开不该自己弹出输入框', (tester) async {
    await openEvent(tester);

    // 子任务进入改名态 —— 此刻有一个输入框，这是**用户主动**要的
    await chooseAction(tester, '子任务甲', '重命名');
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason: '刚点「重命名」，输入框应当在',
    );

    // 收起主线节点：编辑中的那一行被移出树
    await tester.tap(find.byTooltip('收起下级'));
    await tester.pumpAndSettle();
    expect(find.text('子任务甲'), findsNothing, reason: '收起后子行不画了');

    // 再展开：这一行回来时**不该**带着上次那个改名态
    await tester.tap(find.byTooltip('展开下级'));
    await tester.pumpAndSettle();

    expect(
      find.byType(TextField),
      findsNothing,
      reason: '折叠往返之后输入框不该自己弹出来 —— '
          '编辑中的行被移出树时必须把父级的改名状态收掉',
    );
  });

  testWidgets('子任务正在改名时离开详情页，回来也不该自己弹出输入框', (tester) async {
    await openEvent(tester);

    await chooseAction(tester, '子任务甲', '重命名');
    expect(find.byType(TextField), findsOneWidget);

    // 返回外壳（详情页是压在外壳上的一条路由），再重新进这个事件
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('折叠演示'), findsOneWidget, reason: '回到了事件列表');
    await tester.tap(find.text('折叠演示'));
    await tester.pumpAndSettle();

    expect(
      find.byType(TextField),
      findsNothing,
      reason: '离开这一页就等于结束编辑，回来时不该恢复成编辑态',
    );
  });
}
