import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/common/format.dart';
import 'package:guideline/ui/more/due_page.dart';

/// 「到期」页（设计文档 Q29 / Q41 / Q48）：换个截止日就看得到对应区间里的任务。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_due_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  Future<void> openDue(WidgetTester tester, AppController app) async {
    await tester.pumpWidget(MaterialApp(home: DuePage(app: app)));
    await tester.pumpAndSettle();
  }

  testWidgets('有到期的任务时列出它们，不是空状态', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '早就该做的事',
          dueAt: '2020-01-01',
        ));
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '以后再说的事',
          dueAt: '2099-01-01',
        ));

    await openDue(tester, app);

    expect(find.text('早就该做的事'), findsOneWidget, reason: '逾期任务必须出现在「今天」这一档里');
    expect(find.text('以后再说的事'), findsNothing);
    expect(find.textContaining('这个区间没有到期的任务'), findsNothing);
  });

  testWidgets('今天没有东西、但更远的日子有：打开就落在「全部排期」，不是空页', (tester) async {
    // 这条守的是一个真出现的现象：任务都排在很远的将来，默认停在「今天」时
    // 整页看着就是空的（页面没错、范围太窄）。
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '很久以后的事',
          dueAt: '2099-01-01',
        ));

    await openDue(tester, app);

    expect(find.text('很久以后的事'), findsOneWidget, reason: '打开就该看得到内容');
    expect(find.textContaining('全部排期'), findsWidgets, reason: '落在「全部排期」这一档上');
    expect(find.textContaining('所有排了期的任务'), findsOneWidget);
  });

  testWidgets('切档位：7 天内只列近的，已逾期只列过期的', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '过期的',
          dueAt: dateOffset(-3),
        ));
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '三天后的',
          dueAt: dateOffset(3),
        ));
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '很远的',
          dueAt: '2099-01-01',
        ));

    await openDue(tester, app);
    // 有逾期任务 → 自动落在「今天」：含逾期与今天，不含三天后的
    expect(find.text('过期的'), findsOneWidget);
    expect(find.text('三天后的'), findsNothing, reason: '「今天」不发明天的');

    await tester.tap(find.text('7 天内'));
    await tester.pumpAndSettle();
    expect(find.text('三天后的'), findsOneWidget);
    expect(find.text('很远的'), findsNothing);

    await tester.tap(find.text('已逾期'));
    await tester.pumpAndSettle();
    expect(find.text('过期的'), findsOneWidget);
    expect(find.text('三天后的'), findsNothing, reason: '「已逾期」严格早于今天');
  });

  testWidgets('一条排期的都没有：显示空状态，不报错', (tester) async {
    final app = await boot();
    app.ws.createEvent(name: '一件事');

    await openDue(tester, app);

    expect(find.textContaining('这个区间没有到期的任务'), findsOneWidget);
    expect(find.textContaining('全部排期'), findsWidgets, reason: '空状态里也要告诉用户还能切到哪一档');
  });
}
