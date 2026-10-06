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

/// 日期标签：`YYYY-MM-DD` → 「今天 / 明天 / 逾期 N 天 / N 天后」。
///
/// 解析不了的字符串**原样返回**（契约里已被降级为 null，这里只是兜底）。
String describeDate(String? date, {DateTime? now}) {
  final parsed = parseIsoDateTime(date);
  if (parsed == null) return date ?? '';

  final current = now ?? DateTime.now();
  final diff = _daysBetween(parsed, current);
  if (diff == 0) {
    // **今天只给相对说法**（用户 2026-10-03）：不摆绝对日期与时刻。
    // 带时刻且已经过了 ⇒ 说「逾期」（用户挑的词），与 `isOverdue` / `urgencyOf`
    // 同一把尺子；只有日期、或今天的时刻还没到 ⇒ 「今天」。
    return _todayPassed(parsed, date, current) ? '逾期' : '今天';
  }
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

/// 严格解析 `YYYY-MM-DD` 或 `YYYY-MM-DD HH:mm`（2026-10-02，截止时间到分钟）。
///
/// 与 [parseIsoDate] 是**薄壳对薄壳**：实现都在 `Ids` 里，界面只做转发。
/// 只到天的字段（项目日期、事件日期）继续用 [parseIsoDate]；
/// 截止时间那一路用它，于是"08:30 设没设上"与"落盘写的是什么"同源。
DateTime? parseIsoDateTime(String? value) => Ids.parseIsoDateTime(value);

/// 「绝对日期 + 剩余天数」一起显示，例如 `2026-09-30（3 天后）`。
///
/// 任务行、日期字段、日期选择器的提示统一走这个口径 ——
/// 只给相对日会让人不知道到底是几号，只给绝对日期又看不出还剩几天。
///
/// 2026-10-02：值可以是 `YYYY-MM-DD HH:mm`（截止时间精确到分钟）。
/// 带时刻时**原样带上时刻**（`2026-10-03 08:30（明天）`）—— 用户设了钟点就是要看它。
///
/// 2026-10-03 曾短暂加过一条"到期日是今天的就**只给「今天」**、不摆日期与时刻" ——
/// 那是我把用户那句"今天的后缀给「今天」"理解成了"把日期藏掉"。
/// **2026-10-06 已撤回**（用户："我的意思就是 `2026-10-06 08:00（今天）`"）：
/// 今天照常给全称。藏掉那串等于把"今天几点要办"这个最有用的信息删了 ——
/// 而用户恰恰是按钟点被提醒的。
///
/// （相对那一半仍然分两态：今天还没到点说「今天」、已经过点说「逾期」。）
String describeDateWithDays(String? date, {DateTime? now}) {
  if (date == null || date.isEmpty) return '';
  final parsed = parseIsoDateTime(date);
  if (parsed == null) return date; // 解析不了就只回原文
  return '$date（${describeDate(date, now: now)}）';
}

/// 是否已逾期。
///
/// 2026-10-03 改口径（用户）：**带时刻的按绝对时刻判，到点即逾期** ——
/// 今天 08:30 的任务在 09:00 就是逾期（原先要到明天才算）。
/// **只有日期的不动**：它没有"具体时间点"，仍按天，明天才算逾期。
bool isOverdue(String? date, {DateTime? now}) {
  final parsed = parseIsoDateTime(date);
  if (parsed == null) return false;
  final current = now ?? DateTime.now();
  if (_todayPassed(parsed, date, current)) return true;
  return _daysBetween(parsed, current) < 0;
}

/// 「今天 + 带时刻 + 时刻已经过了」。
///
/// 单独抽出来是因为三处（[describeDate] / [isOverdue] / `urgencyOf`）都要问
/// 同一个问题 —— 而这个功能上出过的毛病，几乎全是"同一件事几处各写一遍"。
bool _todayPassed(DateTime parsed, String? raw, DateTime current) =>
    Ids.hasTimeOfDay(raw) && !parsed.isAfter(current);

/// **任务行该不该标红** —— 逾期高亮在界面上的唯一判据。
///
/// 三个条件缺一不可，而它们分属三层信息：任务自己（有没有过点、是不是终态）、
/// 以及它所属的**事件**（是不是已搁置）。
///
/// 为什么要收成一个函数：这三条原本在**列表页**与**事件详情页**各写了一遍，
/// 而详情页那处漏了 `muted` —— 于是同一条任务在详情页是红的、在列表和
/// 逾期横幅里却不算逾期（2026-10-03 发现并修）。这与 Q19 当年收口
/// `overdueTasks()` 是同一个教训：**同一件事写两遍，迟早只剩一遍是对的**。
bool isTaskRowOverdue(
  String? dueAt, {
  required bool pending,
  required bool muted,
  DateTime? now,
}) =>
    !muted && pending && isOverdue(dueAt, now: now);

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
