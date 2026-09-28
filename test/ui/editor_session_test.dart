import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';

/// 「输入完一个内容点击确认之后输入框不会消失，当手动关掉键盘后每次切回该界面
/// 就会弹出键盘」—— 2026-09-28 实机反馈。
///
/// 这条钉的是**编辑会话有没有真的结束**：点完确认之后
///   ① 输入框要换回普通文字；
///   ② 焦点要放掉（否则键盘不会收）；
///   ③ 切走再切回来不许自己又进编辑态。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_editor_close');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.ws.captureInspiration('原来那句话');
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    return app;
  }

  /// 灵感页里那条灵感上的编辑框（点在条目上就变成输入框）。
  Finder editorField() => find.descendant(
        of: find.byType(ListView),
        matching: find.byType(TextField),
      );

  testWidgets('灵感：点条目改成编辑态，点确认之后输入框消失、焦点也放掉', (tester) async {
    await boot(tester);

    await tester.tap(find.text('原来那句话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑内容'));
    await tester.pumpAndSettle();
    expect(editorField(), findsOneWidget, reason: '点「编辑内容」进入编辑态');

    await tester.enterText(editorField(), '改过的那句话');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('确认'));
    await tester.pumpAndSettle();

    expect(find.text('改过的那句话'), findsOneWidget, reason: '改动落到列表上');
    expect(
      editorField(),
      findsNothing,
      reason: '点了确认之后这一行该换回普通文字，输入框要消失',
    );
    // 焦点要"离开输入框"。注意**不能**断言 `primaryFocus == null`：输入框失焦之后
    // 焦点回落到路由自己的 `FocusScopeNode`，那是常态（`scope.hasFocus` 仍是 true）。
    // 真正要看的是"还有没有哪个可编辑控件拿着焦点"。
    final focus = tester.binding.focusManager.primaryFocus;
    expect(
      focus == null || focus is FocusScopeNode,
      isTrue,
      reason: '焦点还挂在 ${focus.runtimeType}（${focus?.debugLabel}）上 —— '
          '不放掉的话键盘不会收，切回来还会再弹一次',
    );
  });

  testWidgets('灵感：确认之后切走再切回来，不许自己又弹输入框', (tester) async {
    await boot(tester);

    await tester.tap(find.text('原来那句话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑内容'));
    await tester.pumpAndSettle();
    await tester.enterText(editorField(), '改过的那句话');
    await tester.tap(find.byTooltip('确认'));
    await tester.pumpAndSettle();

    // 切到项目页再切回来（外壳的四个页签是 KeepAlive 的，状态留着）
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('灵感')),
    );
    await tester.pumpAndSettle();

    expect(
      editorField(),
      findsNothing,
      reason: '切回来自己弹出输入框 = 编辑会话没结束（实机反馈的那一条）',
    );
  });

  testWidgets('清单：添加一条之后输入框收起，不再一直挂着', (tester) async {
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

    await tester.scrollUntilVisible(
      find.text('添加条目'),
      120,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加条目'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '一条新条目');
    await tester.tap(find.byTooltip('添加'));
    await tester.pumpAndSettle();

    expect(app.ws.liveProjects.first.items.single.text, '一条新条目');
    expect(
      find.text('添加条目'),
      findsOneWidget,
      reason: '写完一条之后输入框要收起来（实机反馈：确认之后输入框不消失）',
    );
  });
}
