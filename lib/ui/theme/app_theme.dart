import 'package:flutter/material.dart';

import '../../core/json/canonical.dart';
import '../../core/store/ui_prefs.dart';
import '../common/urgency.dart';
import 'shape_tokens.dart';

/// 主题预设。
///
/// 只存"一个主色"，其余交给 Material 3 的 `colorSchemeSeed` 推导 ——
/// 这样浅色/深色、各组件的配色都自动协调，不需要手写几十个颜色。
class AppThemePreset {
  const AppThemePreset({
    required this.id,
    required this.name,
    required this.seed,
    required this.mood,
  });

  final String id;
  final String name;

  /// 主色种子
  final Color seed;

  /// 一句话说明观感，放在外观页里帮选择
  final String mood;
}

/// 「跟随背景图」的保留 id（选中它时用 `UiPrefs.backgroundSeedHex` 作为种子）。
const String followBackgroundThemeId = 'follow-background';

const List<AppThemePreset> appThemePresets = <AppThemePreset>[
  AppThemePreset(id: 'default', name: '默认蓝', seed: Color(0xFF2F6FEB), mood: '干净、通用'),
  AppThemePreset(id: 'ink', name: '墨黑', seed: Color(0xFF37474F), mood: '克制、少颜色'),
  AppThemePreset(id: 'pine', name: '松绿', seed: Color(0xFF2E7D32), mood: '安静、耐看'),
  AppThemePreset(id: 'clay', name: '陶土', seed: Color(0xFFB4532A), mood: '温暖、有点土气的好看'),
  AppThemePreset(id: 'plum', name: '梅紫', seed: Color(0xFF7B3FA0), mood: '偏文艺'),
  AppThemePreset(id: 'sand', name: '沙金', seed: Color(0xFF9A7B31), mood: '旧纸张的感觉'),
  AppThemePreset(id: 'ocean', name: '海松', seed: Color(0xFF0E7C86), mood: '清爽、偏冷'),
];

AppThemePreset presetOf(String? id) => appThemePresets.firstWhere(
      (AppThemePreset preset) => preset.id == id,
      orElse: () => appThemePresets.first,
    );

/// 当前应该用的主色：预设主色，或「跟随背景图」时用取到的那一个。
Color resolveSeedColor(UiPrefs prefs) {
  if (prefs.themeId == followBackgroundThemeId) {
    return parseHexColor(prefs.backgroundSeedHex) ?? appThemePresets.first.seed;
  }
  return presetOf(prefs.themeId).seed;
}

/// `#RRGGBB` → `Color`；解析不了返回 `null`。
///
/// 形态判定复用 `Canonical.normalizeHexColor`（与 `Project.color` 同一套口径），
/// 免得出现"界面收下了、模型读不出来"的分歧。
Color? parseHexColor(String? hex) {
  final normalized = Canonical.normalizeHexColor(hex);
  if (normalized == null) return null;
  final value = int.tryParse(normalized.substring(1), radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// `Color` → `#rrggbb`（小写，和 `UiPrefs` 的约定一致）。
String toHexColor(Color color) {
  final r = (color.r * 255).round().clamp(0, 255);
  final g = (color.g * 255).round().clamp(0, 255);
  final b = (color.b * 255).round().clamp(0, 255);
  return '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

/// 由偏好生成一整套主题（浅色 / 深色由 [brightness] 决定）。
///
/// 启用背景图时，把大面积的底色（页面底 + AppBar）换成半透明的 surface，
/// 背景才透得出来；文字对比度仍由 `colorScheme` 保证，所以**留了一层底**：
/// 即便把背景强度拉满，也会保留一点底色，不至于读不清字。
ThemeData buildAppTheme(UiPrefs prefs, Brightness brightness) {
  final seed = resolveSeedColor(prefs);
  final base = ThemeData(
    colorSchemeSeed: seed,
    brightness: brightness,
    useMaterial3: true,
    // 紧迫度色阶（绿→红）注册在主题里，控件只按档位取色
    extensions: <ThemeExtension<dynamic>>[
      brightness == Brightness.dark ? UrgencyColors.dark : UrgencyColors.light,
    ],
    // 形状走《界面规范》，能在这里设的就不在控件里各写一遍。
    // `cardTheme` 的 margin 与 shape 要一起给：只改 shape 不改 margin，
    // 圆角会被默认外边距吃掉一块，看着不圆。
    cardTheme: const CardThemeData(margin: EdgeInsets.zero, shape: AppShapes.card),
    dialogTheme: const DialogThemeData(shape: AppShapes.dialog),
    bottomSheetTheme: const BottomSheetThemeData(shape: AppShapes.sheet),
    popupMenuTheme: PopupMenuThemeData(shape: AppShapes.chip),
    snackBarTheme: SnackBarThemeData(shape: AppShapes.chip),
  );
  if (!prefs.hasBackground) return base;

  final surface = base.colorScheme.surface;
  final veil = surface.withValues(alpha: (1 - prefs.backgroundOpacity).clamp(0.35, 0.95));
  return base.copyWith(
    scaffoldBackgroundColor: veil,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: veil,
      scrolledUnderElevation: 0,
    ),
  );
}

/// 背景强度滑杆的取值范围：上限压到 0.6，配合上面的"留底"保证可读性。
const double minBackgroundOpacity = 0.05;
const double maxBackgroundOpacity = 0.6;
