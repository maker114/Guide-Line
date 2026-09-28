import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/inline_editor.dart';

import 'scroll_finders.dart';

/// 「灵感页输入文本后用系统返回键收起键盘，之后任何界面操作都会把键盘重新唤出来」
/// 的复现与护栏（2026-09-28 实机反馈）。
///
/// 机制假设：输入框**仍然持有焦点**，只是键盘被收起了（系统返回键只收键盘、
/// 不动焦点）。之后任何会让这一页重建的操作（切页签、勾选、滚动）都会让
/// `EditableText` 重新去开一次输入连接 —— 键盘就自己回来了。
///
/// 实测：**普通重建不会**重新开键盘（下面第一条），所以机制在别处 ——
/// 第二条按实机动作走：收起键盘之后**切页签**。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_kb_dismiss');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('焦点还在、键盘被系统收起后，一次普通重建不会重开键盘（排除这条假设）',
      (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              TextField(focusNode: focus),
              // 点它会 setState → 触发重建（模拟"之后任何界面操作"）
              StatefulBuilder(
                builder: (context, setState) => TextButton(
                  onPressed: () => setState(() {}),
                  child: const Text('随便一个操作'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: '点输入框 → 拿到焦点');
    expect(tester.testTextInput.isVisible, isTrue, reason: '键盘应当打开');

    // 系统返回键：只收键盘、**不动焦点**
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: '收键盘不该动焦点');
    expect(tester.testTextInput.isVisible, isFalse, reason: '键盘收起来了');

    // 「之后任何界面操作」——一次普通重建
    await tester.tap(find.text('随便一个操作'));
    await tester.pumpAndSettle();

    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: '焦点虽然还在，但用户已经把键盘收起来了 —— 重建不该把它重新唤出来',
    );
  });

  testWidgets('灵感页：收起键盘之后切页签，键盘不许自己回来', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 点灵感页的速记输入框
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue, reason: '点输入框 → 键盘打开');

    // 系统返回键：只收键盘、不动焦点
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);

    // 「之后任何界面操作」——按实机动作：切到项目页
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();

    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: '用户已经收起键盘了，切页签不该把它重新唤出来（实机反馈的那一条）',
    );
  });

  testWidgets('灵感页：键盘收起时放掉速记框的焦点（内容不动）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 先让媒体查询前进一次，拿到"有键盘"的前一态
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    // 只取"速记书写区那个框"（页面顶部第一个）
    final capture = find.byType(TextField).first;
    await tester.enterText(capture, '打一半的字');
    await tester.pumpAndSettle();
    final node = tester.widget<TextField>(capture).focusNode!;
    expect(node.hasFocus, isTrue, reason: '正在输入时焦点在它身上');

    // 模拟系统返回键：键盘收起（viewInsets 归零）
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(
      node.hasFocus,
      isFalse,
      reason: '键盘收起之后必须放掉焦点 —— 不放的话，之后任何一次交互都会让'
          '框架回头补一次输入连接，键盘就自己回来了',
    );
    expect(
      app.ws.inspirationInbox,
      isEmpty,
      reason: '放焦点**不是**提交：打一半的字不该因为收键盘就落盘',
    );
    final field = tester.widget<TextField>(capture);
    expect(field.controller!.text, '打一半的字', reason: '内容留着，再点一下能接着打');
  });

  testWidgets('页内编辑器：键盘收起 = 结束编辑并按确认提交（最小复现）', (tester) async {
    var value = '原来的条目';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => InlineTextField(
              value: value,
              hint: '条目',
              onSubmitted: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    // 真机顺序：点进编辑态 → 键盘跟着弹出来 → 用户按返回键收起
    await tester.tap(find.text('原来的条目'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '改过的条目');
    await tester.pumpAndSettle();

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(value, '改过的条目', reason: '收键盘 = 确认（与点键盘完成键同一条路）');
    expect(find.byType(TextField), findsNothing, reason: '输入框已经变回普通文字');
  });

  testWidgets('清单条目：键盘收起 = 结束这次编辑并按确认提交', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final project = app.ws.createProject(title: '一个目标');
    app.run(() => app.ws.addProjectItem(project.id, '原来的条目'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一个目标').first);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('原来的条目'),
      150,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    // 真机顺序：点进编辑态 → 键盘跟着弹出来 → 用户按返回键收起
    await tester.tap(find.text('原来的条目'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '改过的条目');
    await tester.pumpAndSettle();

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(
      app.ws.findProject(project.id)!.items.single.text,
      '改过的条目',
      reason: '收键盘 = 确认：用户敲完按返回键，意思通常是"我写完了"',
    );
    expect(find.text('改过的条目'), findsOneWidget, reason: '输入框已变回普通文字');
  });
}
