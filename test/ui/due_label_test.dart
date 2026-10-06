import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/ui_prefs.dart';
import 'package:guideline/ui/common/due_label.dart';
import 'package:guideline/ui/theme/app_theme.dart';

/// 到期日「放不下才退成短句」这条判据，以及**预留宽度这个数**。
///
/// 为什么值得一条专门的用例：2026-10-04 用户实机反馈"事件页里一条条长的长短的短、
/// 毫无规律"。查下来不是显示格式的问题，而是三处 `reservedWidth` 全是**估**的
/// （200 / 240 / 300），而实测那一行除日期外只占 ≈74dp —— 白白扔掉 170dp，
/// 于是还剩一半空着的行也被截成短句。这条用例把"不许再拍脑袋给这个数"钉住。
///
/// ⚠️ **宿主机的字体与手机的不是同一套**（测试用等宽字体，同样一串在宿主机上
/// 量出来比真机宽约两成）。所以这里**钉的是机制与那个数**，不钉"某串在真机上
/// 显示成什么" —— 后者只有真机截图能回答（见 `CHANGELOG` 2.7.2 的验收记录）。
void main() {
  /// 把屏幕摆成真机那样（小米 15 Pro：1080px 宽 / 450dpi ⇒ 逻辑宽 384dp）。
  Future<String Function(String, {double? reservedWidth})> pumpPage(
    WidgetTester tester, {
    double width = 384,
  }) async {
    const scale = 2.8125; // 450dpi
    tester.view.physicalSize = Size(width * scale, 800 * scale);
    tester.view.devicePixelRatio = scale;
    addTearDown(tester.view.reset);

    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(UiPrefs.empty, Brightness.light),
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    // 固定"现在"，否则期望值里的「逾期 N 天」会随运行日期飘。
    final now = DateTime(2026, 10, 4);
    return (String value, {double? reservedWidth}) => dueLabelOf(
          captured,
          value,
          now: now,
          reservedWidth: reservedWidth ?? dueRowReservedWidth,
        );
  }

  test('预留宽度是量出来的那个数 —— 改它得先重量（回归：2026-10-04 / 10-06）', () {
    // 不许回到 200 / 240 / 300：那三档会把"还剩一半空间"的行也截成短句。
    // 104 = 行内实测 74 + 卡片左右外边距 24 + 6 余量。
    // ⚠️ 2026-10-06 那条"中间截断"的教训：它**不是**这个数太小造成的，
    // 是详情页把日期也放进了 `Flexible`（与「下级 x/y」各分一半）——
    // 所以别再看到截断就往上加这个数，先去看排版。
    expect(dueRowReservedWidth, 104);
  });

  testWidgets('日期型的全称不再被虚高的预留挤掉', (tester) async {
    final label = await pumpPage(tester);
    // 这一串在宿主字体下约 230dp：**老预留 240 会把它截成「逾期 6 天」**，
    // 新预留 100 下它必须显示全称。
    expect(label('2026-09-28'), '2026-09-28（逾期 6 天）');
    expect(label('2026-10-05'), '2026-10-05（明天）');
  });

  testWidgets('真的放不下时仍然退成短句（降级这条路没有被删掉）', (tester) async {
    // 老预留 240 ⇒ 可用只有 144dp，这一串必退 —— 用它来钉"降级还活着"。
    final label = await pumpPage(tester);
    expect(
      label('2026-09-28', reservedWidth: 240),
      '逾期 6 天',
      reason: '预留 240 时可用只剩 144dp：这一串放不下，应当退成短句',
    );
  });

  testWidgets('同一串：屏幕越窄越容易退成短句（方向不许反）', (tester) async {
    // 真机宽 384dp（预留 132 ⇒ 可用 252）下这一串放得下；
    // 压到 300dp（可用 168）就该退成短句。
    final wide = await pumpPage(tester, width: 384);
    expect(wide('2026-09-28'), '2026-09-28（逾期 6 天）');

    final narrow = await pumpPage(tester, width: 300);
    expect(narrow('2026-09-28'), '逾期 6 天');
  });

  testWidgets('「下级 x/y」这类额外内容按**实测宽度**加进预留', (tester) async {
    final label = await pumpPage(tester);
    // 详情页的算法：固定那一份 + 这段文字的实测宽 + 一段间距。
    // 这里只钉"量出来是正数、而且随文字变宽"——具体像素由字体决定。
    late double narrow;
    late double wide;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(UiPrefs.empty, Brightness.light),
        home: Builder(
          builder: (context) {
            narrow = labelWidthOf(context, '下级 0/7');
            wide = labelWidthOf(context, '下级 12/34');
            return const SizedBox();
          },
        ),
      ),
    );
    expect(narrow, greaterThan(0));
    expect(wide, greaterThan(narrow));
    // 有「下级 x/y」时预留更大 ⇒ 同样的日期更容易被截（这是设计，不是 bug）
    expect(
      label('2026-10-05'),
      '2026-10-05（明天）',
      reason: '「明天」很短，加上下级汇总也还放得下',
    );
  });

  testWidgets('没有到期日 / 空串 ⇒ 空串（不摆一个空的日历图标）', (tester) async {
    final label = await pumpPage(tester);
    expect(label(''), '');
  });
}
