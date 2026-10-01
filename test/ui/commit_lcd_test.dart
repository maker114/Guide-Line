import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/ui_prefs.dart';
import 'package:guideline/ui/common/commit_lcd.dart';
import 'package:guideline/ui/theme/app_theme.dart';
import 'package:guideline/ui/theme/shape_tokens.dart';

/// 提交号点阵屏（handoff 界面优化 #ad6868 第二条）的**外观**那一半。
///
/// 四条口径要守住：
///   · 提交号是**点阵画出来的**，不是普通文字 —— 屏幕上不该出现那串字符本身；
///   · 位数与短码一致（7 位），格子的宽高比 7×9（2026-09-30 用户要求"点阵屏减少一行"）；
///   · **没有提交号时全暗、一个字都不写**（不许出现"未知"这类假文字）；
///   · 2026-10-02 起每排**各说各的语义**（上排云端、下排本机），
///     而且喂进来的必须是短码 —— 见下面那条"读屏不许念 40 位"。
void main() {
  Future<void> pumpLcd(
    WidgetTester tester,
    List<CommitLcdRow> rows, {
    int cellCount = 7,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // 走真主题：外壳是不是"全 App 的那种卡片"要按主题里的 `cardTheme` 判，
        // 用光秃秃的 MaterialApp 就看不到 `AppShapes.card`。
        theme: buildAppTheme(UiPrefs.empty, Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: CommitLcd(rows: rows, cellCount: cellCount),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  CommitLcdRow row(String sha, [String? label]) =>
      CommitLcdRow(sha: sha, semanticsLabel: label ?? '本机内容码 $sha');

  test('位数与短码对齐：7 位、每格 7×9、格间留 1', () {
    expect(CommitLcd.cellWidth, 7);
    expect(CommitLcd.cellHeight, 9);
    expect(CommitLcd.cellGap, 1);
    expect(CommitLcd.columnsFor(7), 55, reason: '7*7 + 6*1');
    expect(CommitLcd.columnsFor(1), 7, reason: '单格不该多算一个间隙');
  });

  testWidgets('外壳就是一张普通卡片：与全 App 的卡片同一档，不另配色', (tester) async {
    await pumpLcd(tester, <CommitLcdRow>[row('abc1234')]);

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
    await pumpLcd(tester, <CommitLcdRow>[row('abc1234')]);

    expect(find.byType(CustomPaint), findsWidgets, reason: '点阵就是一颗颗画上去的');
    expect(
      find.text('abc1234'),
      findsNothing,
      reason: '这是点阵屏，不是一行字 —— 用了 Text 就失去了"LCD"的意思',
    );
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('两排：上排云端、下排本机，各自有自己的语义句', (tester) async {
    // 2026-10-02 用户要求"点阵屏改为两排：上面云端提交码，下面本地提交码"。
    // 这条钉的是**两排都在、且语义不串**（都写成"当前提交号"就等于没说哪排是哪个）。
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, <CommitLcdRow>[
      row('a1b2c3d', '云端提交码 a1b2c3d'),
      row('9f8e7d6', '本机内容码 9f8e7d6'),
    ]);

    expect(find.bySemanticsLabel('云端提交码 a1b2c3d'), findsOneWidget);
    expect(find.bySemanticsLabel('本机内容码 9f8e7d6'), findsOneWidget);

    // 两排就是两颗画家，各自 7 格
    final painters = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(CommitLcd),
            matching: find.byType(CustomPaint),
          ),
        )
        .where((candidate) => candidate.painter is CommitLcdPainter)
        .map((candidate) => candidate.painter! as CommitLcdPainter)
        .toList();
    expect(painters.length, 2, reason: '两排 = 两个点阵画家');
    expect(painters[0].chars, <String>['a', '1', 'b', '2', 'c', '3', 'd']);
    expect(painters[1].chars, <String>['9', 'f', '8', 'e', '7', 'd', '6']);
    handle.dispose();
  });

  testWidgets('两排之间有间距（不是贴在一起）', (tester) async {
    await pumpLcd(tester, <CommitLcdRow>[row('aaaaaaa'), row('bbbbbbb')]);

    final gaps = tester
        .widgetList<SizedBox>(
          find.descendant(
            of: find.byType(CommitLcd),
            matching: find.byType(SizedBox),
          ),
        )
        .where((box) => box.height == CommitLcd.rowGap);
    expect(gaps.length, 1, reason: '两排之间正好一条间距');
  });

  testWidgets('读屏念的是**短码**，不许把 40 位全念出来', (tester) async {
    // 这条是 2026-10-02 修的无障碍 bug 的守卫。
    //
    // 缺陷原样：调用方把**完整 40 位 sha** 递给点阵屏，屏上只画得下 7 格
    // （静默截断，看着没事），而语义标签用的是同一个字段 → **读屏软件念 40 个字符**。
    // 控件自己的文档写的是"提交码（前 7 位十六进制）"，调用方没照做。
    //
    // 所以这条**不给控件兜底**（控件不该替调用方截断，否则 7 格的契约就形同虚设），
    // 而是钉住"递进来的必须是短码"：给 7 位，读屏就念 7 位。
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, <CommitLcdRow>[
      row('a1b2c3d', '云端提交码 a1b2c3d'),
    ]);

    expect(find.bySemanticsLabel('云端提交码 a1b2c3d'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'\w{8,}')),
      findsNothing,
      reason: '语义句里不该出现 8 位以上的连续码 —— 那说明有人把完整 sha 递进来了',
    );
    handle.dispose();
  });

  testWidgets('没有提交号：全暗，一个字符一个字都不写', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, <CommitLcdRow>[row('', '云端提交码未知，还没同步过')]);

    expect(find.byType(Text), findsNothing, reason: '"未知"是文字，这条口径要它闭嘴');
    expect(find.bySemanticsLabel('云端提交码未知，还没同步过'), findsOneWidget);
    expect(find.byType(CommitLcd), findsOneWidget, reason: '空也要把那块屏留在页面上');
    handle.dispose();
  });

  testWidgets('空串与"没有这一排"都画得出来，不给假文字', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, <CommitLcdRow>[row('', '本机内容码未知')]);

    expect(find.bySemanticsLabel('本机内容码未知'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('比 7 位长也只画前 7 格（记账里存的是完整 sha）', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLcd(tester, <CommitLcdRow>[row('abcdef1234567890')]);

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
