import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/ui/common/commit_lcd.dart';

/// 提交号点阵屏（handoff 界面优化 #ad6868 第二条）的**外观**那一半。
///
/// 三条口径要守住：
///   · 提交号是**点阵画出来的**，不是普通文字 —— 屏幕上不该出现那串字符本身；
///   · 位数与短码一致（7 位），格子的宽高比 7×12；
///   · **没有提交号时全暗、一个字都不写**（不许出现"未知"这类假文字）。
void main() {
  Future<void> pumpLcd(WidgetTester tester, String? sha, {int cellCount = 7}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 320, child: CommitLcd(commitSha: sha, cellCount: cellCount)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  test('位数与短码对齐：7 位、每格 7×12、格间留 1', () {
    expect(CommitLcd.cellWidth, 7);
    expect(CommitLcd.cellHeight, 12);
    expect(CommitLcd.cellGap, 1);
    expect(CommitLcd.columnsFor(7), 55, reason: '7*7 + 6*1');
    expect(CommitLcd.columnsFor(1), 7, reason: '单格不该多算一个间隙');
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
    final painter = tester.widget<CustomPaint>(
      find.descendant(of: find.byType(CommitLcd), matching: find.byType(CustomPaint)),
    );
    expect(painter.painter, isA<CommitLcdPainter>());
    expect((painter.painter! as CommitLcdPainter).chars.length, 7);
    expect((painter.painter! as CommitLcdPainter).chars, <String>['a', 'b', 'c', 'd', 'e', 'f', '1']);
    handle.dispose();
  });
}
