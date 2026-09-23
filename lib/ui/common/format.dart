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
  if (diff < 7 * 24 * 60 * 60 * 1000) return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
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
  if (date == null || date.isEmpty) return '';
  final parsed = DateTime.tryParse(date);
  if (parsed == null) return date;

  final today = now ?? DateTime.now();
  final diff = _daysBetween(parsed, today);
  if (diff == 0) return '今天';
  if (diff == 1) return '明天';
  if (diff == -1) return '昨天';
  if (diff < 0) return '逾期 ${-diff} 天';
  if (diff <= 7) return '$diff 天后';
  if (parsed.year == today.year) return '${parsed.month}月${parsed.day}日';
  return date;
}

/// 是否已逾期（到期日严格早于今天）。
bool isOverdue(String? date, {DateTime? now}) {
  if (date == null || date.isEmpty) return false;
  final parsed = DateTime.tryParse(date);
  if (parsed == null) return false;
  return _daysBetween(parsed, now ?? DateTime.now()) < 0;
}

/// 按**日历天**求差，避开夏令时导致的 23/25 小时偏差。
int _daysBetween(DateTime a, DateTime b) => DateTime.utc(a.year, a.month, a.day)
    .difference(DateTime.utc(b.year, b.month, b.day))
    .inDays;

/// 相对今天偏移 [days] 个日历天的 `YYYY-MM-DD`（`DateTime` 会自动进位到相邻月份）。
String dateOffset(int days, {DateTime? now}) {
  final d = now ?? DateTime.now();
  return Ids.todayDate(DateTime(d.year, d.month, d.day + days));
}

String _two(int value) => value.toString().padLeft(2, '0');
