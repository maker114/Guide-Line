import 'package:flutter/material.dart';

import '../../core/ids.dart';
import 'format.dart';
import 'pm24_localizations.dart';

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
/// │ [12:30] [清除时间] [清除日期] [取消] │
/// └──────────────────────────────┘
/// ```
///
/// 2026-10-02：这一版加了**截止时间**（用户："允许设定截止时间精确到分钟"）。
/// 取值形态从 `YYYY-MM-DD` 扩成 `YYYY-MM-DD HH:mm`：
///   · 只点日历某天 ⇒ 仍然是**纯日期**（老用法一个字没变，老数据也不动）；
///   · 再点「选时间…」⇒ 在同一天上补一个 `HH:mm`；
///   · 已经有时间的值，进面板时会**预填**那个时刻，可以改、也可以「清除时间」退回纯日期。
///
/// 时间选择器仍用 Material 那个：**表盘是 5 分钟一格**（用户口径："只需要 5 分钟就行了"），
/// 一屏点两下就完事，不必自己写一套时分滚轮。
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
///   · `YYYY-MM-DD` 或 `YYYY-MM-DD HH:mm` —— 用户选了这一天（可能带时刻）；
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
  // 归口 `Ids.parseIsoDateTime`（2026-10-02）：这个面板现在也处理带时刻的值，
  // 用 `parseIsoDate` 会把 `'2026-10-03 08:30'` 判成 null、把日历落回今天。
  final initial = initialDate ??
      (current == null ? now : (Ids.parseIsoDateTime(current) ?? now));
  // 已有值带没带时刻：决定"选时间"键是预填当前时刻还是预填一个常用钟点。
  final currentTime = current == null
      ? null
      : (Ids.hasTimeOfDay(current) ? Ids.parseIsoDateTime(current) : null);
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
                    // **改日期时保留已设的时刻**（2026-10-06 修）：原先这里无条件 pop
                    // 一个纯日期串，于是"先设时刻、再改日期"会把刚设的时刻冲掉。
                    // 从前这条路少见（没设过日期的条目根本点不到「选时间…」），
                    // 现在它成了主线用法之一，必须留住。
                    if (currentTime != null) {
                      Navigator.of(sheetContext).pop(
                        Ids.isoDateTime(
                          picked,
                          hour: currentTime.hour,
                          minute: currentTime.minute,
                        ),
                      );
                      return;
                    }
                    final month = picked.month.toString().padLeft(2, '0');
                    final day = picked.day.toString().padLeft(2, '0');
                    Navigator.of(sheetContext)
                        .pop('${picked.year}-$month-$day');
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: <Widget>[
                    // 「选时间…」**一直给**（2026-10-06 改，用户要求）。
                    //
                    // 原先这里是 `if (current != null)` ——"没日期就没有'在哪一天几点'
                    // 可谈"。但用户要的正好相反："对于一个没有设置时间的条目，
                    // 需要一开始就可以设置详细时间"：还没设过日期的条目，一上来就该
                    // 能设到几点几分。没日期时的语义落在下面那句 `?? now`：
                    // 选完时刻 ⇒ **今天 + 该时刻**。
                    TextButton.icon(
                      onPressed: () async {
                        final picked = await showTimePicker(
                          context: sheetContext,
                          initialTime: TimeOfDay.fromDateTime(
                            currentTime ??
                                DateTime(now.year, now.month, now.day, 9),
                          ),
                          // 表盘回到**系统那套 12 格**（2026-10-06 用户要求：
                          // "恢复到之前的 12 格轮盘"）—— 2.7.6 里加的那层
                          // `alwaysUse24HourFormat: true` 已撤掉。
                          //
                          // ⚠️ 2026-10-06 试了三版，把结论钉在这里，别再反复：
                          //
                          // ① 只换 `MaterialLocalizations`（下面这层 override）
                          //    ⇒ 只有**表头**变 24 小时，**表盘那圈数字不变**。
                          //    原因（SDK `time_picker.dart:1563`）：12 格模式下
                          //    表盘把**格位**（1–12）交给 `formatHour`，
                          //    它手里**没有"15"这个数**，也就无从显示 13–23。
                          // ② 再加 `alwaysUse24HourFormat: true` ⇒ 表盘会标 0–23，
                          //    但几何变成**两圈**、并且**上午/下午开关消失** ✗
                          //    （用户不需要这个）。
                          // ③ 要"12 格 + 下午标 13–23 + 保留上午/下午开关"，
                          //    **只能自己画表盘** —— 那是新组件，不是改几行。
                          //
                          // 所以这里保持 ① 的状态：**12 格表盘 + 上午/下午开关照旧**，
                          // 表头按 24 小时显示（用户认可的那半）。
                          builder: (pickerContext, child) => Localizations.override(
                            context: pickerContext,
                            delegates: const <LocalizationsDelegate<dynamic>>[
                              Pm24HourZhDelegate(),
                            ],
                            child: child ?? const SizedBox.shrink(),
                          ),
                          // 表盘就是 5 分钟一格（用户口径："只需要 5 分钟就行了"）。
                          // ⚠️ 这里**没有** `minuteInterval` 这个参数 —— Flutter 的
                          // `showTimePicker` 从来不给；表盘的 5 分钟步长是它自己的行为，
                          // 想要任意分钟只能切到键盘输入模式。
                          // 所以"5 分钟"不是我们设的，是它本来就有的 ——
                          // 特意写下来，免得以后有人去传一个不存在的参数。
                        );
                        if (picked == null) return;
                        if (!sheetContext.mounted) return;
                        final day = Ids.parseIsoDateTime(current) ?? now;
                        Navigator.of(sheetContext).pop(
                          Ids.isoDateTime(
                            day,
                            hour: picked.hour,
                            minute: picked.minute,
                          ),
                        );
                      },
                      icon: const Icon(Icons.schedule_outlined, size: 18),
                      label: Text(
                        currentTime == null
                            ? '选时间…'
                            : '时间 ${_hhmm(currentTime)}',
                      ),
                    ),
                    // 「清除时间」只在这一份值**真的带时刻**时给：
                    // 纯日期的值上摆一个"清除时间"是让人以为它有时间。
                    if (currentTime != null)
                      TextButton.icon(
                        onPressed: () => Navigator.of(sheetContext).pop(
                          Ids.isoDateTime(
                            Ids.parseIsoDateTime(current) ?? now,
                          ),
                        ),
                        icon: const Icon(Icons.schedule_send_outlined, size: 18),
                        label: const Text('清除时间'),
                      ),
                    // 清除**只在有值时给**：没有日期的东西不该出现一个空的清除键
                    if (current != null)
                      TextButton.icon(
                        onPressed: () =>
                            Navigator.of(sheetContext).pop(clearDateValue),
                        icon: const Icon(Icons.event_busy_outlined, size: 18),
                        // 名字写全：这是"把日期清掉"，不是"取消这次操作"
                        label: const Text('清除日期'),
                      ),
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

/// `HH:mm`（那个按钮上显示"当前时刻"用；与落盘那一段同一种写法）。
String _hhmm(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
