import 'package:flutter/material.dart';

/// 紧迫度：按到期日与今天的距离分档。
///
/// **没有到期日单独算一档**（`none`），因为"没排期"和"还早"是两件不同的事，
/// 用户要能一眼区分开。
enum Urgency {
  overdue,
  today,
  soon,
  week,
  later,
  none,
}

/// 分档阈值：逾期 / 今天 / 3 天内 / 一周内 / 一周以后 / 没有到期日。
Urgency urgencyOf(String? dueAt, {DateTime? now}) {
  if (dueAt == null || dueAt.isEmpty) return Urgency.none;
  final parsed = DateTime.tryParse(dueAt);
  if (parsed == null) return Urgency.none;

  final days = _daysBetween(parsed, now ?? DateTime.now());
  if (days < 0) return Urgency.overdue;
  if (days == 0) return Urgency.today;
  if (days <= 2) return Urgency.soon;
  if (days <= 7) return Urgency.week;
  return Urgency.later;
}

/// 分组与图例用的短标签。
String urgencyLabel(Urgency urgency) {
  switch (urgency) {
    case Urgency.overdue:
      return '已逾期';
    case Urgency.today:
      return '今天';
    case Urgency.soon:
      return '3 天内';
    case Urgency.week:
      return '一周内';
    case Urgency.later:
      return '一周以后';
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
    required this.soon,
    required this.week,
    required this.later,
    required this.none,
  });

  final Color overdue;
  final Color today;
  final Color soon;
  final Color week;
  final Color later;
  final Color none;

  /// 冷端（还早）绿、热端（逾期）红，中间走黄橙 ——
  /// "越接近越红"要一眼看得出来，而不是靠记图例。
  static const UrgencyColors light = UrgencyColors(
    overdue: Color(0xFFC62828),
    today: Color(0xFFE64A19),
    soon: Color(0xFFEF6C00),
    week: Color(0xFF9E9D24),
    later: Color(0xFF2E7D32),
    none: Color(0xFF8A8A8A),
  );

  static const UrgencyColors dark = UrgencyColors(
    overdue: Color(0xFFFF8A80),
    today: Color(0xFFFFAB91),
    soon: Color(0xFFFFCC80),
    week: Color(0xFFDCE775),
    later: Color(0xFFA5D6A7),
    none: Color(0xFF9E9E9E),
  );

  Color of(Urgency urgency) {
    switch (urgency) {
      case Urgency.overdue:
        return overdue;
      case Urgency.today:
        return today;
      case Urgency.soon:
        return soon;
      case Urgency.week:
        return week;
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
    Color? soon,
    Color? week,
    Color? later,
    Color? none,
  }) =>
      UrgencyColors(
        overdue: overdue ?? this.overdue,
        today: today ?? this.today,
        soon: soon ?? this.soon,
        week: week ?? this.week,
        later: later ?? this.later,
        none: none ?? this.none,
      );

  @override
  UrgencyColors lerp(ThemeExtension<UrgencyColors>? other, double t) {
    if (other is! UrgencyColors) return this;
    return UrgencyColors(
      overdue: Color.lerp(overdue, other.overdue, t)!,
      today: Color.lerp(today, other.today, t)!,
      soon: Color.lerp(soon, other.soon, t)!,
      week: Color.lerp(week, other.week, t)!,
      later: Color.lerp(later, other.later, t)!,
      none: Color.lerp(none, other.none, t)!,
    );
  }
}
