import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/more/more_tab.dart';
import 'package:guideline/ui/more/reminder_page.dart';

/// 「提醒」这一页的接线（ADR-097）：开关点得到吗、改得动吗、**真的落进偏好文件了吗**。
///
/// 规则本身（该不该提醒、什么时候提醒）在 `test/core/reminder_schedule_test.dart`；
/// 这里只管界面接线 —— 两边不重复。
///
/// ⚠️ 用例都靠 `remindersSupportedOverride: true` 才看得到那两格设置：
/// 宿主机不是 Android，默认那条分支只有"电脑端不做提醒"一句。
/// 这个注入点与 `bootstrap` 上那几个（`dataDirectoryOverride` / `aiGenerator`…）
/// 是同一套做法，不是专为这条用例开的后门。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_reminder');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot(WidgetTester tester, {required bool supported}) async {
    final app = await AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      remindersSupportedOverride: supported,
    );
    return app;
  }

  Future<void> pumpPage(WidgetTester tester, AppController app) async {
    await tester.pumpWidget(MaterialApp(home: ReminderPage(app: app)));
    await tester.pumpAndSettle();
  }

  /// 总开关那一格。
  Finder masterTile() => find.widgetWithText(SwitchListTile, '到点提醒我');

  /// 第 N 档那一格里的开关 / 下拉。
  Finder slotSwitch(int slot) => find.descendant(
        of: find.widgetWithText(ListTile, '第 ${slot + 1} 档'),
        matching: find.byType(Switch),
      );

  Finder slotDropdown(int slot) => find.descendant(
        of: find.widgetWithText(ListTile, '第 ${slot + 1} 档'),
        matching: find.byType(DropdownButton<int>),
      );

  /// 落盘的那份界面偏好。
  File prefsFile() => tempDir
      .listSync()
      .whereType<File>()
      .firstWhere((file) => file.path.endsWith('ui_prefs.json'));

  testWidgets('电脑端：只交代"不做提醒"，一个开关都不摆', (tester) async {
    final app = await boot(tester, supported: false);
    await pumpPage(tester, app);

    expect(find.text('电脑端不做提醒'), findsOneWidget);
    expect(find.text('到点提醒我'), findsNothing);
    expect(find.byType(DropdownButton<int>), findsNothing);
  });

  testWidgets('手机端默认：总开关是关的，两档是 1 小时 / 10 分钟', (tester) async {
    final app = await boot(tester, supported: true);
    await pumpPage(tester, app);

    expect(tester.widget<SwitchListTile>(masterTile()).value, isFalse);
    expect(app.prefs.reminderEnabled, isFalse);
    expect(find.text('提前 1 小时'), findsOneWidget);
    expect(find.text('提前 10 分钟'), findsOneWidget);
    // 两档默认都开着（总开关关着与"这一档关掉"是两件事）
    expect(tester.widget<Switch>(slotSwitch(0)).value, isTrue);
    expect(tester.widget<Switch>(slotSwitch(1)).value, isTrue);
  });

  testWidgets('总开关关着时，两档改不动（但值还在，灰掉不等于清掉）', (tester) async {
    final app = await boot(tester, supported: true);
    await pumpPage(tester, app);

    expect(tester.widget<Switch>(slotSwitch(0)).onChanged, isNull);
    expect(tester.widget<DropdownButton<int>>(slotDropdown(0)).onChanged, isNull);
    await tester.tap(slotSwitch(0));
    await tester.pumpAndSettle();
    expect(app.prefs.reminderLeads[0].enabled, isTrue, reason: '点不动，也不该被点掉');
  });

  testWidgets('打开总开关：写进偏好文件', (tester) async {
    final app = await boot(tester, supported: true);
    await pumpPage(tester, app);

    await tester.tap(masterTile());
    await tester.pumpAndSettle();

    expect(app.prefs.reminderEnabled, isTrue);
    expect(prefsFile().readAsStringSync(), contains('"reminderEnabled": true'));
  });

  testWidgets('关掉第 2 档：只有它变成关，第 1 档不动', (tester) async {
    final app = await boot(tester, supported: true);
    await pumpPage(tester, app);
    await tester.tap(masterTile());
    await tester.pumpAndSettle();

    await tester.tap(slotSwitch(1));
    await tester.pumpAndSettle();

    expect(app.prefs.reminderLeads[1].enabled, isFalse);
    expect(app.prefs.reminderLeads[0].enabled, isTrue);
    expect(find.text('这一档已关掉'), findsOneWidget);
  });

  testWidgets('把第 1 档改成「2 小时」：写进偏好，副标题跟着变', (tester) async {
    final app = await boot(tester, supported: true);
    await pumpPage(tester, app);
    await tester.tap(masterTile());
    await tester.pumpAndSettle();

    await tester.tap(slotDropdown(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 小时').last);
    await tester.pumpAndSettle();

    expect(app.prefs.reminderLeads[0].minutes, 120);
    expect(find.text('提前 2 小时'), findsOneWidget);
    expect(prefsFile().readAsStringSync(), contains('"minutes": 120'));
  });

  testWidgets('「自启动」那一条：点开给出步骤与那份实测记录', (tester) async {
    final app = await boot(tester, supported: true);
    await pumpPage(tester, app);

    await tester.tap(find.text('自启动（小米 / HyperOS 必开）'));
    await tester.pumpAndSettle();

    expect(find.textContaining('应用管理'), findsOneWidget);
    // 实测那一句必须原样在：它是"为什么绕不过去"的唯一依据。
    expect(find.textContaining('process is not permitted to auto start'), findsOneWidget);
  });

  testWidgets('「更多」入口的副标题跟着状态走', (tester) async {
    final app = await boot(tester, supported: true);
    // `MoreTab` 自己不监听控制器（真实应用里是外壳那层 `ListenableBuilder` 包的），
    // 所以这里照真实结构包一层 —— 不然改了设置副标题也不会重建。
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: app,
          builder: (context, _) => Scaffold(body: MoreTab(app: app)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已关闭'), findsOneWidget);

    await app.setReminderEnabled(true);
    await tester.pumpAndSettle();
    expect(find.text('提前 1 小时、10 分钟'), findsOneWidget);

    await app.setReminderLeadEnabled(1, false);
    await tester.pumpAndSettle();
    expect(find.text('提前 1 小时'), findsOneWidget);

    await app.setReminderLeadEnabled(0, false);
    await tester.pumpAndSettle();
    expect(find.text('开着，但两档都关掉了'), findsOneWidget);
  });
}
