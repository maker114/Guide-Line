import 'dart:math';

/// ID 与时间。
///
/// ID 一律**由客户端生成**（ADR-002），因此离线也能创建记录；
/// 不引入第三方 uuid 包，避免无谓依赖。
class Ids {
  static final Random _random = Random.secure();

  /// UUID v4（小写、带连字符，符合《数据契约》§1）。
  static String uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256), growable: false);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
        '-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 记录级时间戳：**客户端生成**（ADR-067），毫秒整数。
  static int nowMillis() => DateTime.now().millisecondsSinceEpoch;

  /// 今天的 `"YYYY-MM-DD"`（本地日历，不涉时区换算）。
  static String todayDate([DateTime? now]) {
    final d = now ?? DateTime.now();
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }

  /// 严格解析 `"YYYY-MM-DD"`：**形态与日历都要对**，否则返回 `null`。
  ///
  /// **落盘入口的唯一判据**（《数据契约》§1 的"日期"一行）——
  /// `Canonical.readDate` 就是拿它当关卡。为什么要卡日历而不只卡形态：
  /// `DateTime.tryParse('2026-02-31')` 不会失败，它把越界日期**规范化**成
  /// `2026-03-03` —— 于是同一个值在不同地方算出不同结论。
  /// 2026-10-01 实测到的分叉：三处"逾期"判定里，`isOverdue`（严格）与
  /// `overdueTasks()`（字符串比较）都说**不逾期**，而 `urgencyOf`（当年用
  /// `tryParse`）把 `2026-02-31` 算成 3 月 3 日、于是在 2 月 28 日判成**已逾期并标红**。
  /// 现在 `urgencyOf` 也走这里（见 `lib/ui/common/urgency.dart`）。
  ///
  /// 实现上用"格式化回去必须一模一样"来卡：不合法日期、多一位少一位、
  /// 前后带空白，全都会被这一步挡下。
  ///
  /// ⚠️ **两处细节是刻意的，改它们会静默改变行为**（2026-10-01 一次核验揪出来的）：
  ///
  /// 1. **不做 `trim`**。我第一版写了 `value.trim()`，那让 `' 2026-09-23'`
  ///    从"拒绝"变成"接受" —— 与它替换掉的旧实现（`format.parseIsoDate`，
  ///    直接 `tryParse(date)` 且拿**原串**比对）不一致。这次改动是**收紧**，
  ///    不该悄悄混进一处放宽。要容错空白就单独提一个明确的口径。
  /// 2. **年份要补足 4 位**（`padLeft(4, '0')`）。少了它，`'0999-01-01'`
  ///    回格式化成 `'999-01-01'` ≠ 原文 → 判 `null` → `readDate` 会**拒掉一个
  ///    形态合法、日历上真实存在的日期**，还错报"日历上不存在"。
  ///    旧实现有这一步，我搬代码时漏了。
  static DateTime? parseIsoDate(String? value) {
    if (value == null || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    final year = parsed.year.toString().padLeft(4, '0');
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    return '$year-$month-$day' == value ? parsed : null;
  }

  /// 严格解析 `"YYYY-MM-DD"` **或** `"YYYY-MM-DD HH:mm"`（2026-10-02）。
  ///
  /// 与 [parseIsoDate] 的分工：那个只认纯日期（`Project.date` 这类"只到天"的字段
  /// 继续用它）；这个多认一段可选时刻，供 `Task.due_at`（截止时间精确到分钟）。
  ///
  /// 时刻那一段**必须成对且成范围**：`2026-10-03 25:00`、`2026-10-03 8:5`、
  /// `2026-10-03 08` 一律返回 `null` —— 与日期那一段同一条口径：
  /// 同一个值只能有一种解释，不要靠 `tryParse` 的宽容去猜。
  ///
  /// 返回的 `DateTime` 带时分（纯日期输入时是 `00:00`）。
  static DateTime? parseIsoDateTime(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = _isoDateTimePattern.firstMatch(value);
    if (match == null) return null;
    final date = parseIsoDate(match.group(1));
    if (date == null) return null;
    final hour = int.parse(match.group(2) ?? '0');
    final minute = int.parse(match.group(3) ?? '0');
    return DateTime(date.year, date.month, date.day, hour, minute);
  }

  /// 这个值**带没带时刻**（`"2026-10-03 08:30"` ⇒ true，`"2026-10-03"` ⇒ false）。
  ///
  /// 界面靠它决定"要不要把 08:30 一起显示出来"：纯日期的任务不该凭空多出 `00:00`。
  static bool hasTimeOfDay(String? value) =>
      value != null && _isoDateTimePattern.firstMatch(value)?.group(2) != null;

  /// 组一个 `"YYYY-MM-DD HH:mm"`（[hour] / [minute] 省略时只到天）。
  ///
  /// 与 [parseIsoDateTime] 是**一对**：组出来的东西必须能被它解析回去
  /// （`test/core/ids_test.dart` 守着这条往返）。
  static String isoDateTime(DateTime day, {int? hour, int? minute}) {
    final date = todayDate(day);
    if (hour == null || minute == null) return date;
    return '$date ${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  static final RegExp _isoDateTimePattern =
      RegExp(r'^(\d{4}-\d{2}-\d{2})(?: ([01]\d|2[0-3]):([0-5]\d))?$');
}

/// 同一父节点下兄弟排序的间隔（《数据契约》§1）。
const int orderStep = 1000;

/// 排序键：`order` 升序，`order` 相同则按 `id` 保证确定性。
int compareByOrder(int orderA, String idA, int orderB, String idB) {
  final byOrder = orderA.compareTo(orderB);
  if (byOrder != 0) return byOrder;
  return idA.compareTo(idB);
}
