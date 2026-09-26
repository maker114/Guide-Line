import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/projects/ai_preview_page.dart';

/// AI 覆盖正文的第二道护栏（Q15）：**写入前自动留一份旧版，写入后给"退回上一版"**。
///
/// 验的是接线，不是规则：留档落在哪、能不能读回来由
/// `test/core/app_storage_test.dart` 那几条管，这里只看界面上按得到、按了管用。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guideline_ai_preview_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async =>
      AppController.bootstrap(dataDirectoryOverride: tempDir);

  testWidgets('写入后给「退回上一版」，退回即把正文换回来并销掉留档', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目');
    app.run(() => app.ws.replaceImplementation(project.id, '原来的正文'));

    await tester.pumpWidget(MaterialApp(
      home: AiPreviewPage(
        app: app,
        projectId: project.id,
        projectTitle: '项目',
        generated: 'AI 整理出来的正文',
      ),
    ));
    await tester.pumpAndSettle();

    // 还没覆盖过 → 没有可退回的东西
    expect(find.text('退回上一版'), findsNothing);
    expect(app.implementationSnapshot(project.id), isNull);

    await tester.tap(find.text('写入实现计划'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.implementation, 'AI 整理出来的正文');
    expect(
      app.implementationSnapshot(project.id),
      '原来的正文',
      reason: '覆盖前必须自动留一份，而不是只在说明里劝用户自己备份',
    );
    expect(
      find.text('已写入'),
      findsOneWidget,
      reason: '写入后不自动关页 —— 关了这一页，「退回上一版」就没有落脚处了',
    );

    // 出口在标题栏：写入成功那句轻提示压在页面底部，页脚上的按钮那几秒里点不到
    await tester.tap(find.text('退回上一版'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退回'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.implementation, '原来的正文');
    expect(app.implementationSnapshot(project.id), isNull, reason: '一份留档只值一次反悔');
    expect(find.text('退回上一版'), findsNothing, reason: '退完之后出口也该收起来');
  });

  testWidgets('正文本来就没有内容时不留档（"退回空串"不叫反悔，叫清空）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '新项目');

    await tester.pumpWidget(MaterialApp(
      home: AiPreviewPage(
        app: app,
        projectId: project.id,
        projectTitle: '新项目',
        generated: '第一次整理出来的正文',
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('写入实现计划'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.implementation, '第一次整理出来的正文');
    expect(app.implementationSnapshot(project.id), isNull, reason: '没什么可退回的');
    expect(find.text('退回上一版'), findsNothing);
  });
}
