import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/store/app_paths.dart';
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

    await tester.tap(find.text('写入「如何解决」'));
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

  testWidgets('被新版锁住时：任何写入都要**报错**，不许让异常冒出去（2026-10-01）', (tester) async {
    // 这一条钉的是"被 `StoreLockedByNewerSchema` 挡住时要走 `run()`"。
    // 背景：`AppStorage.save` 现在会在"盘上那份属于更新版本的 App"时**抛**，
    // 而 `run()` 是把它翻成一句人话的地方。谁裸调一个会 persist 的方法，
    // 谁就会把异常冒给框架。
    //
    // ⚠️ 过程中学到一件事，写在这里（它解释了为什么这条用例长这样）：
    // **`setProjectItemDone` 先校验参数、后碰存储** —— 拿一个不存在的项目 id
    // 去调，`run()` 返回的是「项目不存在」，而不是锁那句。
    // 所以"锁"这件事只对**参数合法**的调用可见；而参数合法时，锁在
    // `replaceProjectItems` 那一步就已经被挡下了。
    // 结论：`_revertChecklist` 里那个裸调循环**当前不可达**，
    // 因此**没有**给它加 `run()` 包装（不可测的防卫代码不留）。
    AppPaths(tempDir).ensureDirectories();
    final futureJson = StoreFile.empty().toJson()
      ..['schemaVersion'] = StoreFile.currentSchemaVersion + 1;
    AppPaths(tempDir).storeFile.writeAsStringSync(
      const JsonEncoder.withIndent(null).convert(futureJson),
    );

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(app.startupWarnings, isNotEmpty, reason: '前置：确实处于"被锁住"状态');

    // 一个**参数合法**的写入：这才是能看见"锁"的那条路
    final error = app.run(() => app.ws.createProject(title: '项目'));
    expect(
      error,
      isNotNull,
      reason: '被锁住时**必须返回失败文案**，而不是让异常自己冒出去',
    );
    expect(
      error,
      contains('更新版本'),
      reason: '文案要指向"升级 App"，而不是让用户去查存储空间',
    );

    // 反面对照：参数不合法时先撞参数校验（证明"锁"确实排在后面）
    final invalid = app.run(() => app.ws.setProjectItemDone('p-any', 'x', true));
    expect(
      invalid,
      '项目不存在',
      reason: '这一条记录的是**校验顺序**：先看参数、再看存储。'
          '正因为如此，`_revertChecklist` 里那个裸调循环才不可达',
    );
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

    await tester.tap(find.text('写入「如何解决」'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.implementation, '第一次整理出来的正文');
    expect(app.implementationSnapshot(project.id), isNull, reason: '没什么可退回的');
    expect(find.text('退回上一版'), findsNothing);
  });
}
