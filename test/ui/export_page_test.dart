import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/platform/data_transfer_platform.dart';
import 'package:guideline/ui/more/export_page.dart';

/// Q13：导入前的确认框不能只列"文件里有什么" —— 用户唯一能用来决策的信息是
/// **"我会少掉多少"**。所以这里守住三件事：
///   · 「当前」与「文件」并排，四类记录都给；
///   · 给一句净变化（将减少 / 将增加 / 条数相当）；
///   · 两侧口径一致，都是**活记录**（墓碑不算）—— 墓碑算进去的话两个数就对不上了。
void main() {
  late Directory currentDir;
  late Directory fileDir;

  setUp(() async {
    currentDir = await Directory.systemTemp.createTemp('guideline_export_current');
    fileDir = await Directory.systemTemp.createTemp('guideline_export_file');
  });

  tearDown(() async {
    for (final dir in <Directory>[currentDir, fileDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  Future<AppController> boot(Directory dir) =>
      AppController.bootstrap(dataDirectoryOverride: dir);

  /// 造一份导出文件：字节与真机导出的完全同构（gzip 的整份数据文件）。
  Future<List<int>> exportBytes(void Function(AppController source) seed) async {
    final source = await boot(fileDir);
    seed(source);
    return ExportCodec.encode(
      source.ws.buildStoreFile(),
      exportedAt: 1788652800000,
    );
  }

  /// 打开导出页 → 点「从文件导入」→ 走到确认框。
  ///
  /// 选文件那一步走注入的钩子：`file_picker` 在纯 Dart 测试里没有插件实现，
  /// 而"确认框里到底写了什么"只有走到这一步才验得出来。
  Future<void> openImportDialog(
    WidgetTester tester,
    AppController app,
    List<int> bytes,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ExportPage(
          app: app,
          pickImportFile: () async => PickedTransferFile(
            name: 'guideline-20260923-134500.json.gz',
            bytes: bytes,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
  }

  testWidgets('确认框并排给出「当前」「文件」与净减少，墓碑不计入文件那一侧', (tester) async {
    final app = await boot(currentDir);
    app.ws.createProject(title: '项目一');
    app.ws.createProject(title: '项目二');
    app.ws.captureInspiration('灵感一');
    final event = app.ws.createEvent(name: '事件一');
    app.ws.createTask(eventId: event.id, title: '任务一');
    app.ws.createTask(eventId: event.id, title: '任务二');

    final bytes = await exportBytes((source) {
      source.ws.createProject(title: '文件里的项目');
      // 删掉的项目在文件里是墓碑：它**不该**被算进「文件」那一侧
      final doomed = source.ws.createProject(title: '删掉的项目');
      source.ws.deleteProject(doomed.id);
    });

    await openImportDialog(tester, app, bytes);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('当前：项目 2 · 灵感 1 · 事件 1 · 任务 2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('文件：项目 1 · 灵感 0 · 事件 0 · 任务 0'),
      ),
      findsOneWidget,
      reason: '墓碑不算活记录 —— 算进去就成了「项目 2」，用户会以为文件里多一条',
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('将减少 5 条'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('不会把两份数据合起来'), findsOneWidget);
    expect(
      find.textContaining('替换前当前数据会先整体轮转进备份'),
      findsOneWidget,
      reason: '原有的"能退回"那句警示要留着',
    );
  });

  testWidgets('文件比当前多时写「将增加」', (tester) async {
    final app = await boot(currentDir);
    final bytes = await exportBytes((source) {
      source.ws.createProject(title: '文件里的项目');
    });

    await openImportDialog(tester, app, bytes);

    expect(find.textContaining('当前：项目 0 · 灵感 0 · 事件 0 · 任务 0'), findsOneWidget);
    expect(find.textContaining('文件：项目 1 · 灵感 0 · 事件 0 · 任务 0'), findsOneWidget);
    expect(find.textContaining('将增加 1 条'), findsOneWidget);
  });

  testWidgets('两边条数一样时写「条数相当」', (tester) async {
    final app = await boot(currentDir);
    app.ws.createProject(title: '项目一');
    final bytes = await exportBytes((source) {
      source.ws.createProject(title: '另一份数据里的项目');
    });

    await openImportDialog(tester, app, bytes);

    expect(find.textContaining('条数相当（前后都是 1 条）'), findsOneWidget);
  });

  testWidgets('确认框里说清"不支持合并"，并给出替代做法', (tester) async {
    final app = await boot(currentDir);
    app.ws.createProject(title: '项目一');
    final bytes = await exportBytes((source) {
      source.ws.createProject(title: '文件里的项目');
    });

    await openImportDialog(tester, app, bytes);

    expect(find.textContaining('合并导入'), findsOneWidget, reason: '要说明"把两份合起来"还没有');
    expect(find.textContaining('先「导出并分享」留个档'), findsOneWidget, reason: '要给出替代做法');
  });

  testWidgets('取消就什么都不替换', (tester) async {
    final app = await boot(currentDir);
    app.ws.createProject(title: '项目一');
    final bytes = await exportBytes((source) {
      source.ws.createProject(title: '文件里的项目');
    });

    await openImportDialog(tester, app, bytes);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(app.ws.liveProjects.single.title, '项目一', reason: '没确认就不该替换');
  });
}
