import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/more/archive_page.dart';

/// 归档区「回收站」的几件事（实机反馈 + Q12）：
///   · 每条后面给一个**倒计时**（还剩几天自动清掉）；
///   · 只在回收站里待 `trashRetentionDays` 天，**启动时**清掉过期的墓碑；
///   · 清理了就必须吭声（启动提示条）、说明里写清"到期在下次启动时清"、
///     恢复提示要带**实际范围与条数**。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_archive_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  /// 把两份盘上的墓碑时间戳往前挪 [days] 天（造"很久以前删的"）。
  Future<void> backdate(File storeFile, Set<String> ids, int days) async {
    final raw = jsonDecode(storeFile.readAsStringSync()) as Map<String, dynamic>;
    final collections = raw['collections'] as Map<String, dynamic>;
    final at = DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    for (final collection in collections.values) {
      final items = (collection as Map<String, dynamic>)['items'] as List<dynamic>;
      for (final item in items.cast<Map<String, dynamic>>()) {
        if (ids.contains(item['id'])) item['updated_at'] = at;
      }
    }
    storeFile.writeAsStringSync(jsonEncode(raw));
  }

  testWidgets('回收站每条后面有倒计时', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '删掉的项目');
    app.run(() => app.ws.deleteProject(project.id));

    await tester.pumpWidget(MaterialApp(home: ArchivePage(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('回收站 1'));
    await tester.pumpAndSettle();

    expect(find.text('删掉的项目'), findsOneWidget);
    expect(
      find.textContaining('还有 30 天自动清除'),
      findsOneWidget,
      reason: '刚删的应当显示还剩满 30 天',
    );
  });

  testWidgets('启动时清掉超过 30 天的墓碑，没到期的留着', (tester) async {
    // 先造两条墓碑，再把其中一条的时间戳改到 40 天前，然后**重新启动**
    final first = await boot();
    final stale = first.ws.createProject(title: '删了很久的项目');
    final fresh = first.ws.createProject(title: '昨天删的项目');
    first.run(() => first.ws.deleteProject(stale.id));
    first.run(() => first.ws.deleteProject(fresh.id));

    final storeFile = AppStorage(AppPaths(tempDir)).paths.storeFile;
    await backdate(storeFile, <String>{stale.id}, 40);

    final restarted = await AppController.bootstrap(dataDirectoryOverride: tempDir);

    expect(restarted.lastTrashPurgedCount, greaterThan(0));
    expect(restarted.ws.findProject(stale.id), isNull, reason: '过期墓碑被骨架化了');
    expect(restarted.ws.findProject(fresh.id)!.deleted, isTrue, reason: '没到期的不动');

    await tester.pumpWidget(MaterialApp(home: ArchivePage(app: restarted)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('回收站 1'));
    await tester.pumpAndSettle();
    expect(find.text('昨天删的项目'), findsOneWidget);
    expect(find.text('删了很久的项目'), findsNothing);
  });

  testWidgets('启动清理了非零条数会在外壳上吭声，而且关得掉', (tester) async {
    final first = await boot();
    final stale = first.ws.createProject(title: '很久以前删的项目');
    first.run(() => first.ws.deleteProject(stale.id));

    final storeFile = AppStorage(AppPaths(tempDir)).paths.storeFile;
    await backdate(storeFile, <String>{stale.id}, 40);

    final restarted = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(restarted.lastTrashPurgedCount, greaterThan(0), reason: '先得真的清掉了');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: restarted)));
    await tester.pumpAndSettle();

    final notice = find.textContaining('已超过 30 天，已自动清除');
    expect(notice, findsOneWidget, reason: '数据被自动删掉不能一声不吭');

    // 关掉之后本次运行不再出现（维护动作，不需要反复念）
    await tester.tap(find.byTooltip('知道了'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已自动清除'), findsNothing);
  });

  testWidgets('回收站说明写明"到期在下次启动时自动清除"，倒计时留着', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '删掉的项目');
    app.run(() => app.ws.deleteProject(project.id));

    await tester.pumpWidget(MaterialApp(home: ArchivePage(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('回收站 1'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('到期的条目会在下次启动时自动清除'),
      findsOneWidget,
      reason: '清理只发生在启动时，说明里必须写出来',
    );
    expect(find.textContaining('还有 30 天自动清除'), findsOneWidget, reason: '倒计时不动');
  });

  testWidgets('恢复提示带上实际范围与条数（整条任务线一起回来）', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '被删的事件');
    app.run(() => app.ws.createTask(eventId: event.id, title: '任务一'));
    app.run(() => app.ws.createTask(eventId: event.id, title: '任务二'));
    app.run(() => app.ws.deleteEvent(event.id));
    expect(app.ws.liveTasks, isEmpty, reason: '删事件会把整条任务线一起删掉');

    await tester.pumpWidget(MaterialApp(home: ArchivePage(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('回收站 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已恢复：被删的事件'), findsOneWidget);
    expect(
      find.textContaining('含整条任务线，共 3 条'),
      findsOneWidget,
      reason: '只说一个名字，用户会以为两条任务还留在回收站里',
    );
    expect(app.ws.liveTasks.length, 2, reason: '任务确实一起回来了');
  });

  testWidgets('只恢复一条时提示不带范围（别把简单事说复杂）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '孤单的项目');
    app.run(() => app.ws.deleteProject(project.id));

    await tester.pumpWidget(MaterialApp(home: ArchivePage(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('回收站 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(find.text('已恢复：孤单的项目'), findsOneWidget);
  });
}
