import 'package:flutter/material.dart';

import 'format.dart';

/// 选日期时点「清除」交回来的值。
///
/// 为什么用一个空串而不是 `null`：这个面板有**三种结局** ——
/// 选了一天、清掉、什么都没做就退出。`null` 已经被"取消"占了，
/// 而空串**天生不是合法日期**（`Project.date` / `Task.dueAt` 都是
/// `YYYY-MM-DD` 或 `null`），拿它当"清除"的信号不会与任何真实取值撞上。
const String clearDateValue = '';

/// 选「截止 / 目标日」与「到期日」的**统一面板**（2026-09-27 实机反馈）。
///
/// ```
/// ┌──────────────────────────────┐
/// │ 选择到期日                     │
/// │ 当前：2026-12-31（还有 95 天）  │
/// │ ┌──────────────────────────┐ │
/// │ │        日历本体            │ │
/// │ └──────────────────────────┘ │
/// │        [清除日期]   [取消]    │
/// └──────────────────────────────┘
/// ```
///
/// 为什么不再直接用系统 `showDatePicker`：**它没有"清除"这个出口**。
/// 从前清除只挂在图标的长按上，而"长按可清除"这句提示本身也写在同一个长按的
/// `Tooltip` 里 —— 提示与动作是同一个手势，屏幕上只剩一个 11dp 的小叉暗示。
/// 实机反馈"设了日期取消不掉"就是从这里来的：点开日历**只能改、不能删**。
///
/// 现在改成：点图标 → 弹这个面板 → 清除键就在日历下面，
/// 与"选一天"是同一个界面里的两个平级动作。
///
/// 返回值：
///   · `YYYY-MM-DD` —— 用户选了这一天；
///   · [clearDateValue]（空串）—— 用户点了「清除日期」；
///   · `null` —— 取消 / 返回键，什么都没变。
Future<String?> pickDateSheet(
  BuildContext context, {
  required String title,
  String? current,
  DateTime? initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
}) async {
  final now = DateTime.now();
  final initial = initialDate ??
      (current == null ? now : (DateTime.tryParse(current) ?? now));
  // 日历**不接受首尾之外的那一天**（`CalendarDatePicker` 会直接断言失败）。
  // 当前值本来就可能落在默认区间之外 —— 老数据里的远期日期、或用户上次选到
  // 边界那一年 —— 所以以它为准把区间撑开，而不是让这一页崩掉。
  final lower = firstDate ?? DateTime(now.year - 5);
  final upper = lastDate ?? DateTime(now.year + 20);
  final onlyDate = DateTime(initial.year, initial.month, initial.day);
  final safeInitial = onlyDate.isBefore(lower)
      ? lower
      : (onlyDate.isAfter(upper) ? upper : onlyDate);
  final first = onlyDate.isBefore(lower) ? onlyDate : lower;
  final last = onlyDate.isAfter(upper) ? onlyDate : upper;

  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              // 当前值摆在标题下面：这一版面里"现在是什么"与"要改成什么"同样重要，
              // 而放一条系统选择器的 helpText 里会被日历挤没。
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  current == null ? '现在还没有日期' : '当前：${describeDateWithDays(current)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              // 日历本体给一个确定的高度：`CalendarDatePicker` 内部是可滚动网格，
              // 放在 `mainAxisSize: min` 的列里拿不到固有高度，必须自己框住。
              SizedBox(
                height: 320,
                child: CalendarDatePicker(
                  initialDate: safeInitial,
                  firstDate: first,
                  lastDate: last,
                  onDateChanged: (picked) {
                    final month = picked.month.toString().padLeft(2, '0');
                    final day = picked.day.toString().padLeft(2, '0');
                    Navigator.of(sheetContext)
                        .pop('${picked.year}-$month-$day');
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Row(
                  children: <Widget>[
                    // 清除**只在有值时给**：没有日期的东西不该出现一个空的清除键
                    if (current != null)
                      TextButton.icon(
                        onPressed: () =>
                            Navigator.of(sheetContext).pop(clearDateValue),
                        icon: const Icon(Icons.event_busy_outlined, size: 18),
                        // 名字写全：这是"把日期清掉"，不是"取消这次操作"
                        label: const Text('清除日期'),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  return result;
}
