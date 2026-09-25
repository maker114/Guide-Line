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
