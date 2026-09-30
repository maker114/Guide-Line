import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/ui_prefs.dart';
import 'package:guideline/ui/common/commit_lcd.dart';
import 'package:guideline/ui/theme/app_theme.dart';
import 'package:guideline/ui/theme/shape_tokens.dart';

/// 提交号点阵屏（handoff 界面优化 #ad6868 第二条）的**外观**那一半。
///
/// 三条口径要守住：
///   · 提交号是**点阵画出来的**，不是普通文字 —— 屏幕上不该出现那串字符本身；
///   · 位数与短码一致（7 位），格子的宽高比 7×10；
///   · **没有提交号时全暗、一个字都不写**（不许出现"未知"这类假文字）。
void main() {
  Future<void> pumpLcd(WidgetTester tester, String? sha, {int cellCount = 7}) async {
    await tester.pumpWidget(
      MaterialApp(
        // 走真主题：外壳是不是"全 App 的那种卡片"要按主题里的 `cardTheme` 判，
        // 用光秃秃的 MaterialApp 就看不到 `AppShapes.card`。
        theme: buildAppTheme(UiPrefs.empty, Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 320, child: CommitLcd(commitSha: sha, cellCount: cellCount)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  test('位数与短码对齐：7 位、每格 7×10、格间留 1', () {
    expect(CommitLcd.cellWidth, 7);
    expect(CommitLcd.cellHeight, 10);
    expect(CommitLcd.cellGap, 1);
    expect(CommitLcd.columnsFor(7), 55, reason: '7*7 + 6*1');
    expect(CommitLcd.columnsFor(1), 7, reason: '单格不该多算一个间隙');
  });

  testWidgets('外壳就是一张普通卡片：与全 App 的卡片同一档，不另配色', (tester) async {
    await pumpLcd(tester, 'abc1234');

    final card = tester.widget<Card>(
      find.descendant(of: find.byType(CommitLcd), matching: find.byType(Card)),
    );
    expect(card.elevation, 1, reason: '要的是"轻微浮起"，和灵感页那张速记卡片一致');
    final material = tester.widget<Material>(
      find.descendant(of: find.byType(CommitLcd), matching: find.byType(Material)).first,
    );
    expect(
      material.shape,
      AppShapes.card,
      reason: '圆角走 token（cardTheme 给），控件里不许写 `circular(10)` 这种字面量',
    );
  });

  testWidgets('有提交号：点阵画出来，屏上不出现那串字符本身', (tester) async {
    await pumpLcd(tester, 'abc1234');

    expect(find.byType(CustomPaint), findsWidgets, reason: '点阵就是一颗颗画上去的');
    expect(
      find.text('abc1234'),
      findsNothing,
      reason: '这是点阵屏，不是一行字 —— 用了 Text 就失去了"LCD"的意思',
    );
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('读屏用的是完整提交号（点阵本身读不出来）', (tester) async {
    // 语义句柄要在用例体内 dispose —— `addTearDown` 跑得比测试框架那句
    // "SemanticsHandle was active at the end of the test" 检查更晚，会误报失败。
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, 'abcdef1234567890');

    expect(find.bySemanticsLabel('当前提交号 abcdef1234567890'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('没有提交号：全暗，一个字符一个字都不写', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, '');

    expect(find.byType(Text), findsNothing, reason: '"未知"是文字，这条口径要它闭嘴');
    expect(find.bySemanticsLabel('当前没有提交号'), findsOneWidget);
    expect(find.byType(CommitLcd), findsOneWidget, reason: '空也要把那块屏留在页面上');
    handle.dispose();
  });

  testWidgets('null 与空串一视同仁（老记账读出来就是空串）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, null);

    expect(find.bySemanticsLabel('当前没有提交号'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('比 7 位长也只画前 7 格（记账里存的是完整 sha）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, 'abcdef1234567890');

    final lcd = tester.widget<CommitLcd>(find.byType(CommitLcd));
    expect(lcd.cellCount, 7);
    // 画布宽度按 7 格算，超出的字符不进屏（否则会挤压格子、比例失真）。
    // 外壳改成 `Card` 之后，卡片自己也会带 `CustomPaint`，所以要按画家挑，
    // 不能假设这棵子树里只有一个 —— 那样会撞上 "Bad state: Too many elements"。
    final painter = tester
        .widgetList<CustomPaint>(
          find.descendant(of: find.byType(CommitLcd), matching: find.byType(CustomPaint)),
        )
        .firstWhere((candidate) => candidate.painter is CommitLcdPainter);
    expect(painter.painter, isA<CommitLcdPainter>());
    expect((painter.painter! as CommitLcdPainter).chars.length, 7);
    expect((painter.painter! as CommitLcdPainter).chars, <String>['a', 'b', 'c', 'd', 'e', 'f', '1']);
    handle.dispose();
  });
}
