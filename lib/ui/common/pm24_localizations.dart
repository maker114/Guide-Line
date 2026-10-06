import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

/// 时间表盘的**下午那半圈按 24 小时计数显示**（用户 2026-10-06 要求）。
///
/// 用户原话："恢复到之前的 12 格轮盘，但是当选择下午的时候用 24 小时制表示。"
///
/// Flutter 的表盘只有两档：**12 格**（1–12 + 上午/下午）与 **24 格两圈**
/// （`alwaysUse24HourFormat: true`）—— **没有"12 格几何 + 下午标 24"这一档**。
/// 所以只能换掉"那几个字是怎么算出来的"：表盘数字确实经由
/// `MaterialLocalizations.formatHour()`（SDK `material/time_picker.dart:1532/1544/1563/2188`）。
///
/// **为什么继承 `MaterialLocalizationZh`**：`GlobalMaterialLocalizations` 是抽象类，
/// 真正能用的是各语言的具体类（SDK
/// `generated_material_localizations.dart:44975`）。包装的写法要实现
/// `MaterialLocalizations` 的**约 40 个成员**，写错一处就让"上午/下午/取消/确定"
/// 变英文；继承具体类只需覆盖**一个方法**。
///
/// **为什么需要 `intl` 直接依赖**：那个类的 9 个 `DateFormat` / `NumberFormat`
/// 是**构造参数、父类私有存储**（实例上读不到，分析器会报 `undefined_getter`）
/// ⇒ 自己造这 9 个就要 `intl`。取值口径与 Flutter 自己的
/// `GlobalMaterialLocalizations.delegate.load` 一致。
class Pm24HourZh extends MaterialLocalizationZh {
  const Pm24HourZh({
    required super.fullYearFormat,
    required super.compactDateFormat,
    required super.shortDateFormat,
    required super.mediumDateFormat,
    required super.longDateFormat,
    required super.yearMonthFormat,
    required super.shortMonthDayFormat,
    required super.decimalFormat,
    required super.twoDigitZeroPaddedFormat,
  });

  /// 只在**下午**（12:00–23:59）且当前不是 24 小时制显示时，把小时写成 24 小时数：
  /// 12 → `12`、13 → `13` … 23 → `23`。
  ///
  /// 上午与"已经是 24 小时制"的调用**原样交给父类** —— 表头、无障碍朗读、
  /// 其它用到 `formatHour` 的地方一个字不改。
  @override
  String formatHour(TimeOfDay timeOfDay, {bool alwaysUse24HourFormat = false}) {
    if (!alwaysUse24HourFormat && timeOfDay.hour >= 12) {
      return timeOfDay.hour.toString();
    }
    return super.formatHour(
      timeOfDay,
      alwaysUse24HourFormat: alwaysUse24HourFormat,
    );
  }
}

/// 只把 [Pm24HourZh] 插进**这一个** `showTimePicker` 的局部化环境里。
///
/// 非中文语言**原样退回** Flutter 自己的那套 —— 宁可回到"12 格表盘上的 1–12"，
/// 也不要让选择器缺本地化。
class Pm24HourZhDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const Pm24HourZhDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'zh';

  @override
  Future<MaterialLocalizations> load(Locale locale) async {
    const String name = 'zh';
    return Pm24HourZh(
      fullYearFormat: intl.DateFormat.yMMMM(name),
      compactDateFormat: intl.DateFormat.yMd(name),
      shortDateFormat: intl.DateFormat.yMMMd(name),
      mediumDateFormat: intl.DateFormat.MMMEd(name),
      longDateFormat: intl.DateFormat.yMMMMEEEEd(name),
      yearMonthFormat: intl.DateFormat.yMMM(name),
      shortMonthDayFormat: intl.DateFormat.MMMd(name),
      decimalFormat: intl.NumberFormat.decimalPattern(name),
      twoDigitZeroPaddedFormat: intl.NumberFormat('00', name),
    );
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<MaterialLocalizations> old) =>
      false;
}
