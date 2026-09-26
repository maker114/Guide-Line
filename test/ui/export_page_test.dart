import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/platform/data_transfer_platform.dart';
import 'package:guideline/ui/more/export_page.dart';

/// Q13：导入前的确认框不能只列"文件里有什么" —— 用户唯一能用来决策的信息是
/// **"我会少掉多少"**。所以这里守住三件事：
///   · 「当前」与「文件」并排，四类记录都给；
///   · 给一句净变化（将减少 / 将增加 / 条数相当）；
///   · 两侧口径一致，都是**活记录**（墓碑不算）—— 墓碑算进去的话两个数就对不上了。
///
/// Q25：「合并导入」是同一个页面上的第二条路，守住四件事：
///   · **先预览后落盘** —— 四个集合各给"新增 / 更新 / 保留 / 墓碑"，用户点确认前
///     就能看出多进来什么、覆盖了什么、删掉了什么；
///   · 悬挂引用与同 id 重复要单独说一句（且引用不当场改写）；
///   · "同一秒以本机为准"这条口径必须写在框里；
///   · 报告没有任何变化时**不弹框、不写盘**（写一次就多一份备份、还动了 savedAt）。
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

  /// 造一份"对方文件"：只带指定的记录（没给的集合为空）。
  ///
  /// 「合并导入」的用例要控制**逐集合**的条数，而 `exportBytes` 给的是整个 App 的
  /// 数据 —— 那种写法里四个集合的条数搅在一起，断言只能写成模糊的"含/不含"。
  List<int> fileWith({
    List<Entity> projects = const <Entity>[],
    List<Entity> inspirations = const <Entity>[],
    List<Entity> events = const <Entity>[],
    List<Entity> tasks = const <Entity>[],
  }) =>
      ExportCodec.encode(
        StoreFile(
          documents: <DocName, Document>{
            DocName.projects: Document(name: DocName.projects, items: projects),
            DocName.inspirations: Document(name: DocName.inspirations, items: inspirations),
            DocName.events: Document(name: DocName.events, items: events),
            DocName.tasks: Document(name: DocName.tasks, items: tasks),
          },
          savedAt: 1788652800000,
        ),
        exportedAt: 1788652800000,
      );

  /// 打开导出页 → 点某一条导入入口 → 走到确认框。
  ///
  /// 选文件那一步走注入的钩子：`file_picker` 在纯 Dart 测试里没有插件实现，
  /// 而"确认框里到底写了什么"只有走到这一步才验得出来。
  Future<void> openImportDialog(
    WidgetTester tester,
    AppController app,
    List<int> bytes, {
    String entry = '从文件导入',
  }) async {
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
    await tester.tap(find.widgetWithText(ListTile, entry));
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

  testWidgets('整体替换的确认框指向「合并导入」入口，并给出替代做法', (tester) async {
    final app = await boot(currentDir);
    app.ws.createProject(title: '项目一');
    final bytes = await exportBytes((source) {
      source.ws.createProject(title: '文件里的项目');
    });

    await openImportDialog(tester, app, bytes);

    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('「合并导入」'),
      ),
      findsOneWidget,
      reason: 'Q25 落地之后，这句不能再写"合并导入还没做"，要指向新入口',
    );
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

  // ------------------------------------------------------------ 合并导入（Q25）

  testWidgets('两边各有一条独有记录：预览给「新增 2」，确认后两份都在（合并而不是替换）',
      (tester) async {
    final app = await boot(currentDir);
    app.ws.createProject(title: '本机项目');
    app.ws.captureInspiration('本机灵感');
    final bytes = await exportBytes((source) {
      source.ws.createProject(title: '对方项目');
      source.ws.captureInspiration('对方灵感');
    });

    await openImportDialog(tester, app, bytes, entry: '合并导入');

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.textContaining('项目：新增 1 · 更新 0 · 保留 0 · 墓碑 0'),
      findsOneWidget,
      reason: '四个集合各给四个数，用户才知道这次合并到底动了什么',
    );
    expect(find.textContaining('灵感：新增 1 · 更新 0 · 保留 0 · 墓碑 0'), findsOneWidget);
    expect(find.textContaining('合计：新增 2 · 更新 0 · 保留 0 · 墓碑 0'), findsOneWidget);
    expect(
      find.textContaining('同一秒里的改动以本机为准'),
      findsOneWidget,
      reason: '胜负规则里"相等时本地赢"这条必须让用户看见',
    );

    await tester.tap(find.widgetWithText(FilledButton, '合并'));
    await tester.pumpAndSettle();

    final titles = <String>[for (final p in app.ws.liveProjects) p.title];
    expect(titles, containsAll(<String>['本机项目', '对方项目']), reason: '合并是并入，不是替换');
    expect(
      <String>[for (final i in app.ws.liveInspirations) i.text],
      containsAll(<String>['本机灵感', '对方灵感']),
    );
  });

  testWidgets('同一条记录对方较新：预览说「更新」，落盘后内容真的变了', (tester) async {
    final app = await boot(currentDir);
    final local = app.ws.createProject(title: '本机版本');
    final newer = local.copyWith(title: '对方的新版本', updatedAt: local.updatedAt + 60000);

    await openImportDialog(tester, app, fileWith(projects: <Entity>[newer]), entry: '合并导入');

    expect(find.textContaining('项目：新增 0 · 更新 1 · 保留 0 · 墓碑 0'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '合并'));
    await tester.pumpAndSettle();

    expect(app.ws.liveProjects.single.title, '对方的新版本');
    expect(app.ws.liveProjects.single.id, local.id, reason: '同 id 才算同一条记录');
  });

  testWidgets('同一条记录本地较新：预览说「保留」，落盘后本地那份没被覆盖', (tester) async {
    final app = await boot(currentDir);
    final local = app.ws.createProject(title: '本机版本');
    final older = local.copyWith(title: '对方的旧版本', updatedAt: local.updatedAt - 60000);
    // 另一头还带了一条本机没有的记录：只给"保留"的话合并结果毫无变化，
    // 界面根本不会弹这个框（见下一条用例），也就验不到"保留"那行字。
    final source = await boot(fileDir);
    final otherInspiration = source.ws.captureInspiration('对方独有的灵感');

    await openImportDialog(
      tester,
      app,
      fileWith(projects: <Entity>[older], inspirations: <Entity>[otherInspiration]),
      entry: '合并导入',
    );

    expect(find.textContaining('项目：新增 0 · 更新 0 · 保留 1 · 墓碑 0'), findsOneWidget);
    expect(
      find.textContaining('项目：新增 0 · 更新 1'),
      findsNothing,
      reason: '本地较新时不该说"更新"（那会让用户以为手上这份被换掉了）',
    );

    await tester.tap(find.widgetWithText(FilledButton, '合并'));
    await tester.pumpAndSettle();

    expect(app.ws.liveProjects.single.title, '本机版本', reason: '同一秒/较旧的一方不该覆盖本地');
    expect(app.ws.liveProjects.single.updatedAt, local.updatedAt);
    expect(
      <String>[for (final i in app.ws.liveInspirations) i.text],
      contains('对方独有的灵感'),
      reason: '对方独有的记录照旧要并进来',
    );
  });

  testWidgets('对方文件里有一条墓碑：预览说「墓碑」，落盘后那条记录仍是三 key 骨架', (tester) async {
    final app = await boot(currentDir);
    final local = app.ws.createProject(title: '要被删掉的项目');
    final grave = Tombstone(id: local.id, purgedAt: local.updatedAt + 60000);

    await openImportDialog(tester, app, fileWith(projects: <Entity>[grave]), entry: '合并导入');

    expect(find.textContaining('项目：新增 0 · 更新 0 · 保留 0 · 墓碑 1'), findsOneWidget);
    expect(find.textContaining('墓碑是对方删掉的记录'), findsOneWidget, reason: '墓碑不能被当成"多出来一条数据"');

    await tester.tap(find.widgetWithText(FilledButton, '合并'));
    await tester.pumpAndSettle();

    expect(app.ws.liveProjects, isEmpty, reason: '较新的墓碑生效，记录从主视图消失');
    final onDisk = StoreFile.parse(
      app.storage.paths.storeFile.readAsStringSync(),
      DecodeIssues(),
    );
    final skeleton = onDisk.documentOf(DocName.projects).items.single;
    expect(skeleton, isA<Tombstone>());
    expect(
      skeleton.toJson().keys.toList(),
      <String>['id', 'deleted', 'purged_at'],
      reason: '契约 §3.5：骨架只有这三个 key（丢了它下次导入会把删掉的记录复活）',
    );
  });

  testWidgets('两份完全一致：只说一句「已经一致」，一个字节都不写盘', (tester) async {
    final app = await boot(currentDir);
    app.ws.createProject(title: '项目一');
    final bytes = ExportCodec.encode(app.ws.buildStoreFile(), exportedAt: 1788652800000);
    final before = app.storage.paths.storeFile.readAsBytesSync();

    await openImportDialog(tester, app, bytes, entry: '合并导入');

    expect(find.byType(AlertDialog), findsNothing, reason: '没有变化就不该让人白点一次确认');
    expect(find.textContaining('两份数据已经一致，没有要合并的'), findsOneWidget);
    expect(
      app.storage.paths.storeFile.readAsBytesSync(),
      before,
      reason: '没变化就别写盘 —— 写一次就多一份备份、还动了 savedAt',
    );
  });

  testWidgets('悬挂引用单独说一句，且合并当场不改写引用（交给加载时的规则）', (tester) async {
    final app = await boot(currentDir);
    final source = await boot(fileDir);
    // 指向一个谁都没有的项目：合并结果里这条引用就是"悬挂"的
    final stranded =
        source.ws.createProject(title: '对方项目').copyWith(parentId: 'missing-project-id');

    await openImportDialog(tester, app, fileWith(projects: <Entity>[stranded]), entry: '合并导入');

    expect(
      find.textContaining('引用不会当场改写，交给加载时的悬挂规则处理'),
      findsOneWidget,
      reason: '悬挂是加载层的事，合并只报数 —— 当场改成 null 就再也补不回来了',
    );

    await tester.tap(find.widgetWithText(FilledButton, '合并'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(stranded.id)!.parentProjectId, 'missing-project-id');
  });

  testWidgets('文件里同 id 重复：单独说一句折叠了几条', (tester) async {
    final app = await boot(currentDir);
    final source = await boot(fileDir);
    final duplicated = source.ws.createProject(title: '重复出现的项目');

    await openImportDialog(
      tester,
      app,
      fileWith(projects: <Entity>[duplicated, duplicated]),
      entry: '合并导入',
    );

    expect(
      find.textContaining('同 id 的重复记录，已折叠，只认第一条'),
      findsOneWidget,
      reason: '静默吞掉重复会让"合并后共 N 条"对不上账',
    );
  });
}
