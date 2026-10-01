/// 界面上显示时间/日期的统一口径。
///
/// 纯函数、无 Flutter 依赖，方便单独验证。
library;

import '../../core/ids.dart';

/// 相对时间（灵感、任务列表里比绝对时间有用）。
String relativeTime(int millis, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final diff = current.millisecondsSinceEpoch - millis;
  if (diff < 60 * 1000) return '刚刚';
  if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
  if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
  if (diff < 7 * 24 * 60 * 60 * 1000) {
    return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
  }
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  if (d.year == current.year) return '${d.month}-${d.day}';
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

/// 时间戳 → `YYYY-MM-DD HH:mm`（设置页这类"要看准数"的地方用）。
String formatTimestamp(int millis) {
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
}

/// 日期标签：`YYYY-MM-DD` → 「今天 / 明天 / 逾期 N 天 / N 天后 / M月D日」。
///
/// 解析不了的字符串**原样返回**（契约里已被降级为 null，这里只是兜底）。
String describeDate(String? date, {DateTime? now}) {
  final parsed = parseIsoDate(date);
  if (parsed == null) return date ?? '';

  final today = now ?? DateTime.now();
  final diff = _daysBetween(parsed, today);
  if (diff == 0) return '今天';
  if (diff == 1) return '明天';
  if (diff == -1) return '昨天';
  if (diff < 0) return '逾期 ${-diff} 天';
  // **任何距离都给天数**：早先超过 7 天就退回「M月D日」，等于把"还有多少天"
  // 这个最有用的信息藏起来了（灵感 16）。这里只给"还有几天"，不替代绝对日期 ——
  // 要两者同时出现时用 [describeDateWithDays]。
  return '$diff 天后';
}

/// 严格解析 `YYYY-MM-DD`；不是这个形状、或日历上不存在，就返回 null。
///
/// **不能直接用 `DateTime.tryParse`**：它把 `2026-13-99` / `2026-02-31` 这类越界日期
/// **规范化**成别的日子（13 月 → 次年 1 月、2 月 31 日 → 3 月 3 日），于是
/// "看起来像日期"的脏值会静默变成另一个日期；同一个值在不同解析器下还会算出
/// **不同结论**（2026-10-01 实测：`urgencyOf` 把 `2026-02-31` 判成已逾期并标红，
/// 而 `isOverdue` 与 `overdueTasks()` 都说它不逾期）。
///
/// 现在是**薄壳**：实现搬到了 `lib/core/ids.dart` 的 `Ids.parseIsoDate`，
/// 让"日期算不算数"这件事全应用只有一处说了算（`lib/core` 不能 import `lib/ui`，
/// 所以权威那一份必须在 core）。它同时是 `Canonical.readDate` 用的那个判据 ——
/// 于是**落盘的日期**与**界面算出来的结论**从同一把尺子来。
DateTime? parseIsoDate(String? date) => Ids.parseIsoDate(date);

/// 「绝对日期 + 剩余天数」一起显示，例如 `2026-09-30（3 天后）`。
///
/// 任务行、日期字段、日期选择器的提示统一走这个口径 ——
/// 只给相对日会让人不知道到底是几号，只给绝对日期又看不出还剩几天。
String describeDateWithDays(String? date, {DateTime? now}) {
  if (date == null || date.isEmpty) return '';
  if (parseIsoDate(date) == null) return date; // 解析不了就只回原文
  return '$date（${describeDate(date, now: now)}）';
}

/// 是否已逾期（到期日严格早于今天）。
bool isOverdue(String? date, {DateTime? now}) {
  final parsed = parseIsoDate(date);
  if (parsed == null) return false;
  return _daysBetween(parsed, now ?? DateTime.now()) < 0;
}

/// 按**日历天**求差，避开夏令时导致的 23/25 小时偏差。
int _daysBetween(DateTime a, DateTime b) => DateTime.utc(
  a.year,
  a.month,
  a.day,
).difference(DateTime.utc(b.year, b.month, b.day)).inDays;

/// 回收站条目的倒计时文案（配合 `core/rules/archive_zone.dart` 的 `trashDaysLeft`）。
///
/// 界面上要让人一眼看出"这条还能待多久"，所以按剩余天数换说法：
/// 还剩一天说「明天」，今天该清的说「即将」，其余给具体天数。
String describeTrashCountdown(int daysLeft) {
  if (daysLeft <= 0) return '即将自动清除';
  if (daysLeft == 1) return '明天自动清除';
  return '还有 $daysLeft 天自动清除';
}

/// 相对今天偏移 [days] 个日历天的 `YYYY-MM-DD`（`DateTime` 会自动进位到相邻月份）。
String dateOffset(int days, {DateTime? now}) {
  final d = now ?? DateTime.now();
  return Ids.todayDate(DateTime(d.year, d.month, d.day + days));
}

String _two(int value) => value.toString().padLeft(2, '0');
