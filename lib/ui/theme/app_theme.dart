import 'package:flutter/material.dart';

import '../../core/json/canonical.dart';
import '../../core/models/project_palette.dart';
import '../../core/store/ui_prefs.dart';
import '../common/diff_colors.dart';
import '../common/urgency.dart';
import 'shape_tokens.dart';

/// 全应用的**强调色**。
///
/// 色值定义在 `core/models/project_palette.dart`（**唯一来源**）——
/// 因为自动分配标志色的 `Workspace` 也要用它，而 features 不能依赖 ui。
abstract final class AccentColors {
  /// 项目 / 事件共用的标识色板（现 **16** 支）：前 12 支来自用户给的参考图，
  /// 后 4 支（靛蓝 / 橄榄 / 咖棕 / 青灰）是 2026-09-26 按同一套灰调配方补的 ——
  /// "新色不比旧色更难区分"由 `test/core/project_palette_test.dart` 守着。
  static const List<String> hexes = ProjectPalette.hexes;
}

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
  AppThemePreset(id: 'clay', name: '陶土', seed: Color(0xFFB4532A), mood: '温暖、偏土黄'),
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

/// 中性底色用的种子。
///
/// 选一个**纯灰**：Material 3 会由此推出一整套中性灰的 surface 家族，
/// 这样 7 套主题的"底"是同一套灰，换主题只换前景色（用户明确要求：
/// **不要改变任何背景颜色**）。
///
/// 之所以仍然让 Material 3 推导而不是手写十几个灰值：
/// 浅色/深色两套的层级关系（lowest→highest）由它保证，
/// 手写迟早会出现某一层比相邻层还深这类错误。
const Color _neutralSeed = Color(0xFF8A8A8A);

/// **中文字形的兜底字体链**（电脑端字体发虚、发细的根因就在这儿）。
///
/// Flutter 自带的那套排版只带西文字形（Roboto / Segoe UI），中文要靠系统兜底。
/// 而系统兜底挑出来的是**宋体系**（实测：显式写 `Segoe UI` 与"什么都不指定"
/// 画出来的中文一模一样，而那一版和 `SimSun` 逐字同形）——
/// 笔画细、有衬线，在浅色底上看着就是"发虚、不像这个应用的字"。
///
/// 这里**只给兜底链、不给 `fontFamily`**：
///   · 西文仍然走平台默认（Windows 是 Segoe UI），不动；
///   · 只有默认字体没有的字形才会往下找，所以第一支能命中的就是中文用的那支；
///   · 列里不存在的字体在 Flutter 里是**无害的空档**（不会报错、直接跳过），
///     所以一份清单可以同时覆盖 Windows（雅黑）、华为（HarmonyOS Sans）、
///     以及装了 Noto 的机器。
///
/// 顺序即优先级：雅黑笔画与西文 UI 最搭，其次是华为与 Noto 这两支开源无衬线。
const List<String> cjkFontFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'HarmonyOS Sans SC',
  'Noto Sans SC',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'DengXian',
  'PingFang SC',
];

/// 只换**前景**：把主题色装进那些"文字 / 图标 / 选中态"的 role，
/// **一个 surface / background 相关的字段都不碰**。
///
/// 哪些算前景（会换）：
///   · 主 / 次 / 三色及其 `on` 色 —— 按钮文字、图标、选中胶囊、链接；
///   · `outline` / `outlineVariant` —— 描边与次级文字；
///   · `error` / `onError` / `errorContainer` / `onErrorContainer` —— 报错与危险动作；
///   · `inversePrimary` / `onInverseSurface` / `inverseSurface` 那一组。
/// 哪些算背景（**保持中性灰**）：surface 家族全部、`background`、
/// 各种 `*Container`（它们给卡片/面板当底）。
///
/// 唯一的例外是 `primaryContainer` / `secondaryContainer` / `tertiaryContainer`
/// 与 `inverseSurface`：它们既当"底"又必须跟着主色走（选中胶囊、FilledButton
/// 的底色就是它们，纯中性灰会看不出选中）。这是刻意保留的三个，
/// 它们的**对比伙伴** `onPrimaryContainer` 等也一起换，保证读得清。
ColorScheme applyAccent(ColorScheme neutral, Color accent, Brightness brightness) {
  // 压在强调色上的字取纯黑或纯白 —— **判据只能是强调色自己的明暗**，
  // 不能看整体是浅色还是深色主题：墨黑主题的强调色是深灰（#37474F），
  // 配白字对比度只有 1.8，读不清（这条是被对比度测试抓出来的）。
  //
  // 阈值取 0.5（感知中点）：12 个预设里只有沙金（#9A7B31，明度 0.30）在临界附近，
  // 取白字仍有 3.0:1，够读。
  final onAccent = accent.computeLuminance() > 0.5
      ? const Color(0xFF1A1A1A)
      : Colors.white;

  return neutral.copyWith(
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: accent,
    onPrimaryContainer: onAccent,
    secondary: accent,
    onSecondary: onAccent,
    secondaryContainer: accent.withValues(alpha: 0.22),
    onSecondaryContainer: accent,
    tertiary: accent,
    onTertiary: onAccent,
    tertiaryContainer: accent.withValues(alpha: 0.18),
    onTertiaryContainer: accent,
    outline: accent.withValues(alpha: 0.55),
    outlineVariant: neutral.outlineVariant,
    inversePrimary: accent,
  );
}

/// 把一个颜色**彻底去色**，只保留明度。
///
/// 为什么需要它：Material 3 即使给一个纯灰种子（`#8A8A8A`），
/// 经 HCT 色调板推导后出来的"灰"仍带极轻微的冷色偏
/// （实测浅色 surface = 245,250,251 而不是 245,245,245）。
/// 用户要求背景是**中性灰**，所以这里把 surface 家族统一去色 ——
/// 明度层级完全保留（lowest→highest 的相对关系不变），只是不再偏色。
Color _neutralize(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withSaturation(0).toColor();
}

/// 由偏好生成一整套主题（浅色 / 深色由 [brightness] 决定）。
///
/// **底色全中性、主题色只上前景**（见 [applyAccent]）：
/// 换主题时页面底、卡片底、输入框底都不变，变的只有文字、图标与选中态。
///
/// 启用背景图时，把大面积的底色（页面底 + AppBar）换成半透明的 surface，
/// 背景才透得出来；文字对比度仍由 `colorScheme` 保证，所以**留了一层底**：
/// 即便把背景强度拉满，也会保留一点底色，不至于读不清字。
ThemeData buildAppTheme(UiPrefs prefs, Brightness brightness) {
  final seed = resolveSeedColor(prefs);
  // 底色永远从中性灰推导；主题色只往上叠前景 role
  final fromNeutral = ColorScheme.fromSeed(seedColor: _neutralSeed, brightness: brightness);
  // 再把 surface 家族统一去色，保证是**真中性灰**而不是"几乎中性"
  final neutral = fromNeutral.copyWith(
    surface: _neutralize(fromNeutral.surface),
    surfaceDim: _neutralize(fromNeutral.surfaceDim),
    surfaceBright: _neutralize(fromNeutral.surfaceBright),
    surfaceContainerLowest: _neutralize(fromNeutral.surfaceContainerLowest),
    surfaceContainerLow: _neutralize(fromNeutral.surfaceContainerLow),
    surfaceContainer: _neutralize(fromNeutral.surfaceContainer),
    surfaceContainerHigh: _neutralize(fromNeutral.surfaceContainerHigh),
    surfaceContainerHighest: _neutralize(fromNeutral.surfaceContainerHighest),
    onSurface: _neutralize(fromNeutral.onSurface),
    onSurfaceVariant: _neutralize(fromNeutral.onSurfaceVariant),
    inverseSurface: _neutralize(fromNeutral.inverseSurface),
    onInverseSurface: _neutralize(fromNeutral.onInverseSurface),
  );
  final base = ThemeData(
    colorScheme: applyAccent(neutral, seed, brightness),
    brightness: brightness,
    useMaterial3: true,
    // 中文字形走这条兜底链（不设 `fontFamily`，西文仍是平台默认）。
    // 详见 [cjkFontFallback] 上方的说明：不设它，Windows 上中文会落成宋体。
    fontFamilyFallback: cjkFontFallback,
    // 紧迫度色阶（绿→红）与版本差异红绿都注册在主题里，控件只按档位取色
    extensions: <ThemeExtension<dynamic>>[
      brightness == Brightness.dark ? UrgencyColors.dark : UrgencyColors.light,
      brightness == Brightness.dark ? DiffColors.dark : DiffColors.light,
    ],
    // 形状走《界面规范》，能在这里设的就不在控件里各写一遍。
    // `cardTheme` 的 margin 与 shape 要一起给：只改 shape 不改 margin，
    // 圆角会被默认外边距吃掉一块，看着不圆。
    cardTheme: const CardThemeData(margin: EdgeInsets.zero, shape: AppShapes.card),
    dialogTheme: const DialogThemeData(shape: AppShapes.dialog),
    bottomSheetTheme: const BottomSheetThemeData(shape: AppShapes.sheet),
    popupMenuTheme: PopupMenuThemeData(shape: AppShapes.chip),
    snackBarTheme: SnackBarThemeData(shape: AppShapes.chip),
    // **滚动时标题栏不要变色**（实机反馈"有滚动内容时顶栏会变深"）。
    // 那是 Material 3 AppBar 的默认行为：内容滚到它下面时抬 elevation，
    // 并在底色上叠一层 surfaceTint，看起来就"变深/发脏"。
    // 这个应用的标题栏本来就与页面同底，所以直接关掉抬升与着色。
    appBarTheme: const AppBarTheme(
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
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

/// 把偏好里的主题模式（`system` / `light` / `dark`）翻成 `MaterialApp` 要的
/// [ThemeMode]。
///
/// **翻译只有这一处**：core 层不认识 Flutter（`ui_prefs` 里存的是字符串），
/// 而界面侧好几个地方要用同一个口径 —— 写两遍迟早会漂成"设置页说深色、
/// 实际还是跟系统"。
///
/// 认不出来的值（不该出现，`UiPrefs.fromJson` 已经把坏值收回默认）一律按
/// **跟随系统**处理，与默认值同一条口径。
ThemeMode themeModeOf(UiPrefs prefs) => switch (prefs.themeMode) {
      UiPrefs.themeModeLight => ThemeMode.light,
      UiPrefs.themeModeDark => ThemeMode.dark,
      _ => ThemeMode.system,
    };

/// 主题模式在界面上的中文名（设置页与「更多」页副标题共用同一份）。
String themeModeLabel(String mode) => switch (mode) {
      UiPrefs.themeModeLight => '浅色',
      UiPrefs.themeModeDark => '深色',
      _ => '跟随系统',
    };
