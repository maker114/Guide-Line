import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 界面里那个**页面级**的纵向滚动体。
///
/// 有了"左右滑动切页"之后，外壳的 `PageView` 也是一个 `Scrollable`：
/// `find.byType(Scrollable)` 会一次找到两个 —— `scrollUntilVisible` 内部取的是
/// `.single`，会直接抛 `Too many elements`；退而求其次用 `.first` 又可能滚错东西
/// （横向的 `PageView` 怎么滚都不会把列表项滚出来）。
///
/// 列表类页面都是**纵向**滚的，所以按方向挑；`EditableText` 内部那个
/// `restorationId == 'editable'` 的 `Scrollable` 是输入框自己的，不算"页面在滚"。
final Finder verticalScrollable = find.byWidgetPredicate(
  (Widget widget) =>
      widget is Scrollable &&
      widget.axisDirection == AxisDirection.down &&
      widget.restorationId != 'editable',
);

/// 在日期面板的日历里点「今天」那一格。
///
/// 日期面板（`lib/ui/common/due_sheet.dart`）用的是 `CalendarDatePicker`：
/// **点哪一天就立刻落定**，没有第二个"确定"可点 —— 所以测试里不能再找 `OK`。
///
/// 为什么按"今天"这个日号找：日历显示的是当前月，写死"点 15 号"那样的断言
/// 会随运行日期漂；而且网格里可能同时出现**邻月的同号**（上月末 / 下月初），
/// 所以按**可见矩形最靠上**的那一个来点（当前月的日号总在邻月之上），
/// 日号 `>= 15` 时当前月那一格是当月最后一行，仍在上邻月那格之下，这个判据都成立。
Future<void> tapTodaysDay(WidgetTester tester) async {
  final day = DateTime.now().day.toString();
  final candidates = find.text(day);
  expect(candidates, findsWidgets, reason: '日历里应当有「$day」这一格');
  if (candidates.evaluate().length == 1) {
    await tester.tap(candidates);
    return;
  }
  Rect? top;
  for (var i = 0; i < candidates.evaluate().length; i += 1) {
    final rect = tester.getRect(candidates.at(i));
    if (top == null || rect.top < top.top) top = rect;
  }
  await tester.tapAt(top!.center);
}
