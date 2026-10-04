import 'package:flutter/material.dart';

import '../../core/ids.dart';

/// 紧迫度：按到期日与今天的距离分档。
///
/// **没有到期日单独算一档**（`none`），因为"没排期"和"还早"是两件不同的事，
/// 用户要能一眼区分开。
///
/// 档位与标签**必须对得上**：标签写「3 天内」就真的是第 1~3 天。
/// （早期版本判据是 `days <= 2` 而标签写「3 天内」，只覆盖到第 2 天 —— 已修正。）
enum Urgency {
  overdue,
  today,
  within3,
  within5,
  within7,
  later,
  none,
}

/// 分档阈值：逾期 / 今天 / 3 天内 / 5 天内 / 7 天内 / 7 天后 / 没有到期日。
///
/// **解析走 `Ids.parseIsoDate`，不再用 `DateTime.tryParse`**（2026-10-01 归口）。
/// 这一处正是当初"三处逾期判定分叉"的源头：`tryParse` 会把 `'2026-02-31'`
/// **规范化**成 3 月 3 日，于是在 2 月 28 日把它判成"已逾期"并标红，
/// 而同屏的 `isOverdue`、`Workspace.overdueTasks()` 都说它不逾期。
/// 落盘入口（`Canonical.readDate`）现在会拒掉这种值，所以当前触发不到；
/// 但归口之后**即使有脏值从别的路径进来，三处的结论也不会再分叉**。
///
/// 2026-10-02：换成 [Ids.parseIsoDateTime] —— 截止时间可以带 `HH:mm`，
/// 而 `parseIsoDate` 只认纯日期，带时刻的值会被它判 `null`、
/// 于是这条任务**静默掉进「没有到期日」**（分档、配色、分组一起错）。
///
/// 2026-10-03 改口径（用户）：**带时刻的按绝对时刻判，到点即逾期** ——
/// 今天 08:30 的任务在 09:00 就是 `overdue`（原先算「今天」）。
/// **只有日期的不动**：它没有"具体时间点"，仍按天，明天才算逾期。
Urgency urgencyOf(String? dueAt, {DateTime? now}) {
  if (dueAt == null || dueAt.isEmpty) return Urgency.none;
  final parsed = Ids.parseIsoDateTime(dueAt);
  if (parsed == null) return Urgency.none;

  final current = now ?? DateTime.now();
  if (Ids.hasTimeOfDay(dueAt) && !parsed.isAfter(current)) return Urgency.overdue;

  final days = _daysBetween(parsed, current);
  if (days < 0) return Urgency.overdue;
  if (days == 0) return Urgency.today;
  if (days <= 3) return Urgency.within3;
  if (days <= 5) return Urgency.within5;
  if (days <= 7) return Urgency.within7;
  return Urgency.later;
}

/// 分组与图例用的短标签。
String urgencyLabel(Urgency urgency) {
  switch (urgency) {
    case Urgency.overdue:
      return '已逾期';
    case Urgency.today:
      return '今天';
    case Urgency.within3:
      return '3 天内';
    case Urgency.within5:
      return '5 天内';
    case Urgency.within7:
      return '7 天内';
    case Urgency.later:
      return '7 天后';
    case Urgency.none:
      return '没有到期日';
  }
}

/// 排序用：越紧迫越靠前。
int urgencyRank(Urgency urgency) => urgency.index;

/// 按**日历天**求差，避开夏令时导致的 23/25 小时偏差。
int _daysBetween(DateTime a, DateTime b) => DateTime.utc(a.year, a.month, a.day)
    .difference(DateTime.utc(b.year, b.month, b.day))
    .inDays;

/// 紧迫度配色（**放在主题里**，见 `app_theme.dart` 的注册）。
///
/// 之所以做成 `ThemeExtension` 而不是散在控件里的常量：
/// 颜色属于主题，浅色/深色各要一套；控件只负责"按档位取色"，
/// 这样"取消硬编码颜色"这条约束不用为了一个渐变色阶破例。
@immutable
class UrgencyColors extends ThemeExtension<UrgencyColors> {
  const UrgencyColors({
    required this.overdue,
    required this.today,
    required this.within3,
    required this.within5,
    required this.within7,
    required this.later,
    required this.none,
  });

  final Color overdue;
  final Color today;
  final Color within3;
  final Color within5;
  final Color within7;
  final Color later;
  final Color none;

  /// 冷端（还早）绿、热端（逾期）红，中间走黄橙 ——
  /// "越接近越红"要一眼看得出来，而不是靠记图例。
  static const UrgencyColors light = UrgencyColors(
    overdue: Color(0xFFC62828),
    today: Color(0xFFE64A19),
    within3: Color(0xFFEF6C00),
    within5: Color(0xFFF9A825),
    within7: Color(0xFF9E9D24),
    later: Color(0xFF2E7D32),
    none: Color(0xFF8A8A8A),
  );

  static const UrgencyColors dark = UrgencyColors(
    overdue: Color(0xFFFF8A80),
    today: Color(0xFFFFAB91),
    within3: Color(0xFFFFCC80),
    within5: Color(0xFFFFE082),
    within7: Color(0xFFDCE775),
    later: Color(0xFFA5D6A7),
    none: Color(0xFF9E9E9E),
  );

  Color of(Urgency urgency) {
    switch (urgency) {
      case Urgency.overdue:
        return overdue;
      case Urgency.today:
        return today;
      case Urgency.within3:
        return within3;
      case Urgency.within5:
        return within5;
      case Urgency.within7:
        return within7;
      case Urgency.later:
        return later;
      case Urgency.none:
        return none;
    }
  }

  /// 从当前主题取配色；主题没注册时退回浅色那套（不该发生，但别让界面崩）。
  static UrgencyColors ofContext(BuildContext context) =>
      Theme.of(context).extension<UrgencyColors>() ?? light;

  @override
  UrgencyColors copyWith({
    Color? overdue,
    Color? today,
    Color? within3,
    Color? within5,
    Color? within7,
    Color? later,
    Color? none,
  }) =>
      UrgencyColors(
        overdue: overdue ?? this.overdue,
        today: today ?? this.today,
        within3: within3 ?? this.within3,
        within5: within5 ?? this.within5,
        within7: within7 ?? this.within7,
        later: later ?? this.later,
        none: none ?? this.none,
      );

  @override
  UrgencyColors lerp(ThemeExtension<UrgencyColors>? other, double t) {
    if (other is! UrgencyColors) return this;
    return UrgencyColors(
      overdue: Color.lerp(overdue, other.overdue, t)!,
      today: Color.lerp(today, other.today, t)!,
      within3: Color.lerp(within3, other.within3, t)!,
      within5: Color.lerp(within5, other.within5, t)!,
      within7: Color.lerp(within7, other.within7, t)!,
      later: Color.lerp(later, other.later, t)!,
      none: Color.lerp(none, other.none, t)!,
    );
  }
}
