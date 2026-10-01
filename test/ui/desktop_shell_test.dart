import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/sync_status_indicator.dart';
import 'package:guideline/ui/desktop/desktop_shell.dart';
import 'package:guideline/ui/projects/project_tab.dart';

/// 电脑端外壳（`DesktopShell`）与"按宽度分流"这条判断。
///
/// 守三件事：
///   ① 宽度到 [desktopMinWidth] 才换桌面外壳，窄了仍然是手机那套（两套并存）；
///   ② 侧栏八项的标签与顺序，以及"点哪一项、内容区就翻到哪一页"；
///   ③ 嵌进来的那几页**不自带标题栏**（否则外壳顶上两条标题叠着）。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_desktop_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 起一份空数据的控制器（这一组只测外壳的形状，不造数据）。
  Future<AppController> boot() =>
      AppController.bootstrap(dataDirectoryOverride: tempDir);

  /// 把外壳摆在一个指定宽度的窗口里 —— 与真机上"把窗口拉宽/拉窄"同一件事。
  ///
  /// 用 `MediaQuery` 给尺寸而不是 `tester.view.physicalSize`：分流那行读的是
  /// `MediaQuery.sizeOf(context)`，直接喂它最贴近被测代码。
  Future<void> pumpAt(WidgetTester tester, AppController app, double width) async {
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: MaterialApp(home: AppShell(app: app)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('宽度够：换成侧栏外壳，底栏与手机那套一律不出现', (tester) async {
    final app = await boot();
    await pumpAt(tester, app, desktopMinWidth);
    await tester.pumpAndSettle();

    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(AppBottomNav), findsNothing, reason: '桌面上不该还有底部四格');
    expect(find.byType(PageView), findsNothing, reason: '桌面上没有左右滑动切页');
  });

  testWidgets('宽度不够：仍然是手机外壳（两套并存，不是替代）', (tester) async {
    final app = await boot();
    // 比断点少 1dp：边界是"达到才换"，差一点都不该换
    await pumpAt(tester, app, desktopMinWidth - 1);
    await tester.pumpAndSettle();

    expect(find.byType(DesktopShell), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(AppBottomNav), findsOneWidget);
  });

  testWidgets('侧栏八项：标签与顺序固定，默认停在「项目」', (tester) async {
    final app = await boot();
    await pumpAt(tester, app, 1200);
    await tester.pumpAndSettle();

    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isTrue, reason: '宽屏上侧栏展开显示文字，不是只剩图标');
    expect(rail.minExtendedWidth, 210);

    final labels = rail.destinations
        .cast<NavigationRailDestination>()
        .map((each) => (each.label as Text).data)
        .toList();
    expect(labels, <String>[
      '灵感',
      '项目',
      '事件',
      '今天 / 本周',
      '全部任务',
      '搜索',
      '归档区',
      '设置',
    ]);
    expect(rail.selectedIndex, 1, reason: '默认落在「项目」这一项');

    // 内容区同一时刻只显示一页，但八页都留在树上（各自的状态不丢）
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 1);
    expect(stack.children.length, labels.length, reason: '侧栏几项、内容区就有几页');
  });

  testWidgets('点侧栏切页：内容区翻过去，标题栏跟着走', (tester) async {
    final app = await boot();
    await pumpAt(tester, app, 1200);
    await tester.pumpAndSettle();

    await tester.tap(find.text('归档区').first);
    await tester.pumpAndSettle();

    var stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 6, reason: '「归档区」是第六项（从 0 数）');
    // 标题栏写的是当前那一项的名字 —— 侧栏里也有同名的那一个，
    // 所以"能找到两个"才是对的（栏里一个、顶上标题一个）
    expect(find.text('归档区'), findsNWidgets(2));

    await tester.tap(find.text('灵感').first);
    await tester.pumpAndSettle();
    stack = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(stack.index, 0);
    expect(find.text('灵感'), findsNWidgets(2));
  });

  testWidgets('顶部标题栏：同步指示器与「关于」都在，且不重复页面自己的标题栏',
      (tester) async {
    final app = await boot();
    await pumpAt(tester, app, 1200);
    await tester.pumpAndSettle();

    expect(find.byType(SyncStatusIndicator), findsOneWidget);
    final about = find.widgetWithText(TextButton, '关于');
    expect(about, findsOneWidget);

    // 标题栏这一条**整条都在窗口内**：`关于` 的右缘不许越过窗口右边
    // （实机截图里右上角是空的，这里量一遍把"被挤出可视区"这条路堵死）。
    final window = tester.getRect(find.byType(DesktopShell));
    final aboutRect = tester.getRect(about);
    expect(aboutRect.right, lessThanOrEqualTo(window.right));
    expect(aboutRect.top, greaterThanOrEqualTo(window.top));
    expect(aboutRect.width, greaterThan(0));

    // 切到「搜索」：搜索页自己那个 `AppBar` 必须关掉（`embedded: true`）。
    // 桌面外壳的整体标题栏是自绘的（不是 `AppBar`），所以这时树里
    // **一个 `AppBar` 都不该有** —— 有的话就是页面那条漏出来了。
    await tester.tap(find.text('搜索').first);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing, reason: '搜索页的标题栏必须让位');
    expect(find.text('搜索'), findsNWidgets(2), reason: '侧栏一项 + 顶部标题一条');

    // 换到「项目」：项目页本来就没有自己的 AppBar，这里应当是空态文案
    await tester.tap(find.text('项目').first);
    await tester.pumpAndSettle();
    expect(find.byType(ProjectTab), findsOneWidget);
    expect(find.text('还没有项目'), findsOneWidget);
  });
}
