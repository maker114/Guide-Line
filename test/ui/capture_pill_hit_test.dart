import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/projects/project_tab.dart';

/// 速记胶囊的**命中区必须与它画出来的形状一致**（两端半圆的胶囊）。
///
/// 「收起 / 展开分类时会莫名弹出输入框」这条实机反馈查到最后是两个来源：
///   1. 改名状态残留 —— 见 `stale_rename_test.dart`（已修）；
///   2. **速记胶囊抢走行尾操作区的点击** —— 就是这一条。
///
/// 胶囊浮在内容**上面**，`InkWell` 的命中区原本是**整个 80×48 矩形**，
/// 而画出来是胶囊：两个角（各约 12×12）属于"画不到、却点得到"的死区。
/// 项目行的 ⋮ 正好压在右边缘，矮屏上就会落进右下那个角 ——
/// 点 ⋮ 打到的是胶囊 → 跳到灵感页并聚焦速记输入框。
///
/// 这条用例不去判断"⋮ 能不能点得到"（那取决于胶囊盖住多少内容，是版式问题），
/// 只钉住**这不是胶囊该吃的那一下**：形状外的像素，胶囊不许接。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_pill_hit');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> bootOnShortScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    for (var i = 0; i < 30; i += 1) {
      app.ws.createProject(title: '项目$i');
    }

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomNav),
        matching: find.text('项目'),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 这个点上，胶囊自己（它的 `InkWell`）有没有被命中。
  bool pillHitAt(WidgetTester tester, Offset point) {
    final pillFinder = find.byType(CapturePillButton);
    final inkWell = find.descendant(of: pillFinder, matching: find.byType(InkWell));
    final targets = <RenderObject>{
      for (var i = 0; i < inkWell.evaluate().length; i += 1)
        inkWell.evaluate().elementAt(i).renderObject!,
    };
    final result = HitTestResult();
    tester.binding.hitTestInView(result, point, tester.view.viewId);
    return result.path.any((entry) => targets.contains(entry.target));  }

  testWidgets('胶囊两个角上的像素不该被它接住（那是"画不到却点得到"的死区）', (tester) async {
    await bootOnShortScreen(tester);

    final pill = tester.getRect(find.byType(CapturePillButton));
    expect(pill.isEmpty, isFalse, reason: '非灵感页才有这颗胶囊');
    expect(
      pill.width,
      greaterThan(pill.height),
      reason: '胶囊是"宽 > 高"才有两个角；宽等于高时它就是个圆，这条不适用',
    );

    // 四个角各取最外沿 2dp 的那个像素：胶囊是两端半圆，那里**一定**在形状外
    final corners = <String, Offset>{
      '左上': Offset(pill.left + 2, pill.top + 2),
      '右上': Offset(pill.right - 2, pill.top + 2),
      '左下': Offset(pill.left + 2, pill.bottom - 2),
      '右下': Offset(pill.right - 2, pill.bottom - 2),
    };
    for (final entry in corners.entries) {
      expect(
        pillHitAt(tester, entry.value),
        isFalse,
        reason: '胶囊的${entry.key}角（${entry.value}）在形状之外，不该接住点击 —— '
            '接住了就说明命中区还是整个矩形，行尾贴在右边缘的 ⋮ 会被它抢走',
      );
    }

    // 反证：形状**里面**的点必须还能点（别把命中区收没了）
    expect(
      pillHitAt(tester, pill.center),
      isTrue,
      reason: '胶囊中心必须仍然点得到',
    );
    expect(
      pillHitAt(tester, Offset(pill.right - 2, pill.center.dy)),
      isTrue,
      reason: '右端半圆的圆心那一列是形状内的，必须点得到',
    );
  });

  testWidgets('矮屏上：与胶囊重叠的那些行 ⋮，没被胶囊整块吃掉', (tester) async {
    // 这一条是 2026-09-28 改写的：原版断言"胶囊与行 ⋮ **一个像素都不许重叠**"，
    // 于是 body 底部必须留出 80dp 空档 —— 而那条空档正是实机反馈里
    // "下半部被截断"的元凶（卡片最后一条被齐刷刷裁掉一半）。
    //
    // 现在改成断言**功能**而不是几何：重叠可以有（胶囊本来就是浮在内容上的），
    // 但压在它底下的行 ⋮ 的矩形里**必须还剩得下能落地的点** —— 全被吃掉就等于
    // 那一行的菜单没有出路。靠的是胶囊的命中区已收成画出来的形状。
    //
    // **范围说明**：这里只量"有没有落在胶囊之外的采样点"，**不判断那一点是不是⋮**
    // （⋮ 自己能不能点得到取决于胶囊盖住多少内容，是版式问题，见文件头）。
    await bootOnShortScreen(tester);

    final pill = tester.getRect(find.byType(CapturePillButton));
    expect(pill.isEmpty, isFalse, reason: '非灵感页才有这颗胶囊');

    final menuButtons = find.descendant(
      of: find.byType(ProjectTab),
      matching: find.byType(PopupMenuButton<String>),
    );
    expect(menuButtons, findsWidgets, reason: '项目页应当画出带 ⋮ 的行');

    // 只挑**与胶囊有交集**的那些 —— 没有交集的行本来就不可能被抢
    final overlapping = <Rect>[
      for (var i = 0; i < menuButtons.evaluate().length; i += 1)
        tester.getRect(menuButtons.at(i)),
    ].where(pill.overlaps).toList();

    for (final rect in overlapping) {
      // 扫一圈：只要还有**一个**点能落到胶囊之外（也就是 ⋮ 自己的地盘），
      // 这一行就没有被整块吃掉
      var reachable = 0;
      for (var dx = 2.0; dx < rect.width; dx += 4) {
        for (var dy = 2.0; dy < rect.height; dy += 4) {
          final point = Offset(rect.left + dx, rect.top + dy);
          if (!pillHitAt(tester, point)) reachable += 1;
        }
      }
      expect(
        reachable,
        greaterThan(0),
        reason: '行 ⋮（$rect）整块都被速记胶囊（$pill）吃掉了 —— '
            '它得点得到，否则最后那一行的菜单就没有出路',
      );
    }
  });
}
