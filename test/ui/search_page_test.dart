import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/more/search_page.dart';

/// 搜索页的搜索框（实机反馈）：**页面上要有一个明显的框**。
///
/// 原来它是标题栏里一个没有边框的输入框 —— 看着像一行说明文字，
/// 第一眼认不出"这里能打字"。现在是一个带搜索图标、胶囊底色的框。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_search_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  testWidgets('搜索框在页面上、带搜索图标与提示词', (tester) async {
    final app = await boot();
    app.run(() => app.ws.createProject(title: '指南线'));

    await tester.pumpWidget(MaterialApp(home: SearchPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget, reason: '标题栏只写标题，输入框挪到页面里');

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(find.descendant(of: field, matching: find.byIcon(Icons.search)), findsOneWidget);
    expect(find.text('搜项目 / 事件 / 任务 / 灵感'), findsOneWidget);

    // 输入框**不在**标题栏里（那正是原来"看不出来能打字"的原因）
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(TextField)),
      findsNothing,
    );
  });

  testWidgets('打字就有结果，清空按钮能把框清干净', (tester) async {
    final app = await boot();
    app.run(() => app.ws.createProject(title: '指南线'));

    await tester.pumpWidget(MaterialApp(home: SearchPage(app: app)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '指南线');
    await tester.pumpAndSettle();

    expect(find.text('指南线'), findsWidgets);
    expect(find.textContaining('命中 1 条'), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.text('输入关键词开始搜索'), findsOneWidget);
  });
}
