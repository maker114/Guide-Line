/// 提醒的**两档提前量**（一档一条）。
///
/// 为什么做成"固定两档的数组"而不是"任意多条"（用户 2026-10-03 定）：
/// 一条任务能触发的通知数因此有个**可控上限**（最多两条），
/// 设置页一眼看完，也不会长出"我到底配了几条规则"这种要翻半天的问题。
/// 每档可以**单独关掉**（只改 `enabled`），总开关在 `UiPrefs.reminderEnabled`。
///
/// 落在 `lib/core` 而不是界面层：它进的是 `ui_prefs.json`，是**契约**的一部分，
/// 读侧要能容忍坏值（见 [normalize]），而 core 是纯 Dart、不认识 Flutter。
class ReminderLead {
  const ReminderLead({required this.minutes, required this.enabled});

  /// 提前多少分钟（1 ~ [maxMinutes]）。
  final int minutes;

  /// 这一档开着没有。关掉只影响"排不排它"，不抹掉 [minutes]——
  /// 与 AI / GitHub 那两个开关同一条口径：开关只决定用不用，不决定记不记得住。
  final bool enabled;

  /// 一档最少 1 分钟。
  ///
  /// 0 是**被拒绝**的：提前 0 分钟 = 到期那一刻，而用户这一轮的口径是
  /// "到点本身不提醒"（只在到期之前提醒），所以 0 不是一个有意义的取值。
  static const int minMinutes = 1;

  /// 一档最多 7 天。给个上界是为了挡住"提前 100 年"这种明显是坏值的输入，
  /// 顺带让界面上的滑杆 / 输入框有个确定的量程。
  static const int maxMinutes = 7 * 24 * 60;

  /// 档数固定两档。
  static const int slotCount = 2;

  /// 出厂默认：**提前 1 小时**、**提前 10 分钟**，都开着（用户 2026-10-03 定）。
  static const List<ReminderLead> defaults = <ReminderLead>[
    ReminderLead(minutes: 60, enabled: true),
    ReminderLead(minutes: 10, enabled: true),
  ];

  ReminderLead copyWith({int? minutes, bool? enabled}) => ReminderLead(
        minutes: minutes ?? this.minutes,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'minutes': minutes,
        'enabled': enabled,
      };

  /// 读一档：**坏值一律回落到 [fallback]，不抛**（与 `ui_prefs.json` 里
  /// 其它偏好同一套口径 —— 这个文件损坏的代价应该只是"设置回默认"）。
  ///
  /// 越界（0、负数、超过一周、非整数）与缺键走同一条路；`enabled` 缺键时
  /// 只认 `true` 才开，别的（含 `null`）都算关。
  static ReminderLead fromJson(Object? raw, {required ReminderLead fallback}) {
    if (raw is! Map) return fallback;
    final minutes = raw['minutes'];
    if (minutes is! int || minutes < minMinutes || minutes > maxMinutes) {
      return fallback;
    }
    return ReminderLead(minutes: minutes, enabled: raw['enabled'] == true);
  }

  /// 把读进来的东西整成**恰好两档**。
  ///
  /// 多出来的丢掉、少了的用 [defaults] 补齐 —— 契约上这个键永远是一个长度 2 的数组，
  /// 于是界面与规则层都不必再防"只有一档"这种半成品状态。
  static List<ReminderLead> normalize(Object? raw) {
    final list = raw is List ? raw : const <Object?>[];
    return <ReminderLead>[
      for (var i = 0; i < slotCount; i++)
        i < list.length
            ? fromJson(list[i], fallback: defaults[i])
            : defaults[i],
    ];
  }

  @override
  String toString() => 'ReminderLead($minutes 分钟, ${enabled ? '开' : '关'})';
}
