import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/ui/more/archive_page.dart';

/// 归档区「回收站」的两件事（实机反馈）：
///   · 每条后面给一个**倒计时**（还剩几天自动清掉）；
///   · 只在回收站里待 `trashRetentionDays` 天，启动时清掉过期的墓碑。
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
}
