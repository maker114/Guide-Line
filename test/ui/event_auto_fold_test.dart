import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';

/// 事件页的「已完成老节点自动收起」。
///
/// 规则：从**第一个未完成的主线节点**往回看，只留它的**上一个**节点，
/// 再往前的已完成节点收起（全做完了就不折叠）。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_fold_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> openEventWith(
    WidgetTester tester,
    List<({String title, bool done})> tasks,
  ) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '折叠演示');
    for (final spec in tasks) {
      final task = app.ws.createTask(eventId: event.id, title: spec.title);
      if (spec.done) {
        app.run(() => app.ws.setTaskStatus(task.id, NodeStatus.done));
      }
    }

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('折叠演示'));
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('一堆已完成 + 一个进行中：只留当前节点的上一个', (tester) async {
    await openEventWith(tester, <({String title, bool done})>[
      (title: '第一步', done: true),
      (title: '第二步', done: true),
      (title: '第三步', done: true),
      (title: '第四步', done: false),
    ]);

    // 第四步是当前节点，第三步是它的上一个 → 都可见
    expect(find.text('第四步'), findsOneWidget);
    expect(find.text('第三步'), findsOneWidget);
    // 更早的两个已完成节点被收起
    expect(find.text('第一步'), findsNothing, reason: '隔了两个的已完成节点应当收起');
    expect(find.text('第二步'), findsNothing, reason: '只保留紧邻的上一个节点');
  });

  testWidgets('只有紧邻的一个已完成节点时，不折叠任何东西', (tester) async {
    await openEventWith(tester, <({String title, bool done})>[
      (title: '上一步', done: true),
      (title: '当前步', done: false),
    ]);

    expect(find.text('上一步'), findsOneWidget);
    expect(find.text('当前步'), findsOneWidget);
  });

  testWidgets('全部完成时不折叠（否则整条线会消失）', (tester) async {
    await openEventWith(tester, <({String title, bool done})>[
      (title: '甲', done: true),
      (title: '乙', done: true),
      (title: '丙', done: true),
    ]);

    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    expect(find.text('丙'), findsOneWidget);
  });

  testWidgets('全是未完成的节点时不折叠', (tester) async {
    await openEventWith(tester, <({String title, bool done})>[
      (title: '一', done: false),
      (title: '二', done: false),
      (title: '三', done: false),
    ]);

    expect(find.text('一'), findsOneWidget);
    expect(find.text('二'), findsOneWidget);
    expect(find.text('三'), findsOneWidget);
  });
}
