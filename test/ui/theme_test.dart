import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/ui_prefs.dart';
import 'package:guideline/ui/theme/app_theme.dart';

/// 主题只改**前景**，绝不动**背景**。
///
/// 这是用户明确定下的规则：换主题时页面底、卡片底、输入框底必须完全一样，
/// 变的只有文字、图标与选中态。之前是用 `colorSchemeSeed: 种子` 生成整套配色，
/// 于是选个绿色主题连页面底都会泛绿 —— 这条测试就是防它退回去。
///
/// 做法：拿两套差异很大的主题，逐个比对 `ColorScheme` 里**所有背景相关 role**，
/// 必须相等；再抽查几个前景 role，必须**不相等**（否则说明主题没生效）。
void main() {
  /// `ColorScheme` 里所有"当底色用"的角色。
  ///
  /// 这个清单要跟着 Flutter 走：新增 surface 家族成员时也要加进来，
  /// 否则新角色会悄悄跟着主色跑而没人发现。
  const List<String> backgroundRoles = <String>[
    'surface',
    'surfaceDim',
    'surfaceBright',
    'surfaceContainerLowest',
    'surfaceContainerLow',
    'surfaceContainer',
    'surfaceContainerHigh',
    'surfaceContainerHighest',
    'onSurface',
    'onSurfaceVariant',
    'inverseSurface',
  ];

  /// 前景角色（会随主题变，抽查即可）。
  ///
  /// **不含 `onPrimary`**：它按强调色的明暗取黑或白，是"压在强调色上的字"，
  /// 本来就不该随主题变（见下面那条单独的测试）。
  ///
  /// **不含 `outline`**：2026-10-18 起它是中性灰（描边与次级文字，
  /// 含已完成 / 划掉的标题），不跟主题色走 —— 它由下面那条单独守。
  const List<String> foregroundRoles = <String>[
    'primary',
    'primaryContainer',
    'onSecondaryContainer',
  ];

  Color roleOf(ColorScheme scheme, String name) {
    switch (name) {
      case 'surface':
        return scheme.surface;
      case 'surfaceDim':
        return scheme.surfaceDim;
      case 'surfaceBright':
        return scheme.surfaceBright;
      case 'surfaceContainerLowest':
        return scheme.surfaceContainerLowest;
      case 'surfaceContainerLow':
        return scheme.surfaceContainerLow;
      case 'surfaceContainer':
        return scheme.surfaceContainer;
      case 'surfaceContainerHigh':
        return scheme.surfaceContainerHigh;
      case 'surfaceContainerHighest':
        return scheme.surfaceContainerHighest;
      case 'onSurface':
        return scheme.onSurface;
      case 'onSurfaceVariant':
        return scheme.onSurfaceVariant;
      case 'inverseSurface':
        return scheme.inverseSurface;
      case 'primary':
        return scheme.primary;
      case 'primaryContainer':
        return scheme.primaryContainer;
      case 'onSecondaryContainer':
        return scheme.onSecondaryContainer;
      case 'outline':
        return scheme.outline;
      case 'tertiary':
        return scheme.tertiary;
      default:
        throw ArgumentError('未收录的 role：$name');
    }
  }

  ThemeData themeOf(String themeId, Brightness brightness) => buildAppTheme(
        UiPrefs(themeId: themeId),
        brightness,
      );

  for (final brightness in Brightness.values) {
    final label = brightness == Brightness.dark ? '深色' : '浅色';

    test('$label：换主题时所有背景 role 完全不变', () {
      // 拿差异最大的两套：墨黑（近黑）与沙金（偏黄），以及默认蓝
      final ids = <String>['ink', 'default', 'sand'];
      final schemes = <String, ColorScheme>{
        for (final id in ids) id: themeOf(id, brightness).colorScheme,
      };

      for (final role in backgroundRoles) {
        final reference = roleOf(schemes['default']!, role);
        for (final id in ids) {
          expect(
            roleOf(schemes[id]!, role),
            reference,
            reason: '$role 在主题「$id」下变了 —— 背景不该跟着主题走（$label）',
          );
        }
      }
    });

    test('$label：前景 role 确实跟着主题变（否则说明主题根本没生效）', () {
      final blue = themeOf('default', brightness).colorScheme;
      final sand = themeOf('sand', brightness).colorScheme;
      for (final role in foregroundRoles) {
        expect(
          roleOf(blue, role),
          isNot(roleOf(sand, role)),
          reason: '$role 应当随主题变化（$label）',
        );
      }
    });

    test('$label：描边 / 次级文字（outline）是中性灰，不跟主题色走', () {
      // 完成 / 划掉的标题、未勾记号、没设标识色的描边都取它 ——
      // 2026-10-18 被对比度测试与实机反馈一起钉住：灰就是灰，不能是主题色。
      final outlines = <String, Color>{
        for (final id in <String>['default', 'ink', 'sand', 'plum'])
          id: themeOf(id, brightness).colorScheme.outline,
      };
      expect(
        outlines.values.toSet().length,
        1,
        reason: 'outline 不该随主题色变化（$label）',
      );
      final color = outlines['default']!;
      final r = (color.r * 255).round();
      final g = (color.g * 255).round();
      final b = (color.b * 255).round();
      expect(
        (r - g).abs() <= 1 && (g - b).abs() <= 1,
        isTrue,
        reason: 'outline 在「default」/$label 下是 rgb=$r,$g,$b，应当是中性灰',
      );
    });
  }

  test('深色：每个主题的强调色都抬到与页面底 ≥ 4.5:1', () {
    // 主题种子是给浅底设计的：墨黑 #37474F、梅紫 #7B3FA0 直接放到深底上
    // 只有 1.9:1 / 2.7:1，文字、图标、选中态全糊在页面底里（用户反馈）。
    // 深色统一抬明度到 WCAG AA 的正文门槛，浅色不动。
    for (final preset in appThemePresets) {
      final scheme = themeOf(preset.id, Brightness.dark).colorScheme;
      final ratio = contrastRatio(scheme.primary, scheme.surface);
      expect(
        ratio,
        greaterThanOrEqualTo(minDarkAccentContrast),
        reason: '「${preset.name}」在深色下的强调色对比度只有 '
            '${ratio.toStringAsFixed(2)}:1，低于 $minDarkAccentContrast:1',
      );
    }
  });

  test('深色：页面底与面板拉开，容器族逐档递增', () {
    final scheme = themeOf('default', Brightness.dark).colorScheme;
    final levels = <Color>[
      scheme.surfaceContainerLowest,
      scheme.surface,
      scheme.surfaceContainerLow,
      scheme.surfaceContainer,
      scheme.surfaceContainerHigh,
      scheme.surfaceContainerHighest,
    ];
    for (var i = 1; i < levels.length; i++) {
      expect(
        levels[i].computeLuminance(),
        greaterThan(levels[i - 1].computeLuminance()),
        reason: '第 $i 档面板色没有比上一档亮 —— 层级会被压平',
      );
    }
    // 卡片取 surfaceContainerLow：M3 默认只比页面底亮 8 个灰阶（≈1.08:1），
    // 深色屏幕上几乎同色，这就是"面板不突出"的根因。
    final ratio = contrastRatio(scheme.surfaceContainerLow, scheme.surface);
    expect(
      ratio,
      greaterThanOrEqualTo(1.25),
      reason: '卡片与页面底只有 ${ratio.toStringAsFixed(2)}:1，面板会糊进页面底',
    );
    for (final color in levels) {
      final r = (color.r * 255).round();
      final g = (color.g * 255).round();
      final b = (color.b * 255).round();
      expect(
        (r - g).abs() <= 1 && (g - b).abs() <= 1,
        isTrue,
        reason: '面板色阶必须仍是中性灰（rgb=$r,$g,$b）',
      );
    }
  });

  test('底栏底色：深色取面板色（不再与页面底同色），浅色仍与页面底同色', () {
    final dark = themeOf('default', Brightness.dark).colorScheme;
    expect(bottomNavColorOf(dark), dark.surfaceContainerHigh);
    expect(
      bottomNavColorOf(dark),
      isNot(dark.surface),
      reason: '深色下底栏画成 surface 会与页面底一模一样（实机反馈"融为一体"）',
    );
    final light = themeOf('default', Brightness.light).colorScheme;
    expect(bottomNavColorOf(light), light.surface, reason: '浅色靠阴影浮起，不动');
  });

  test('外观页色块 = 当前亮暗下实际生效的强调色', () {
    // 深色下主题色会被抬明度（见 `effectiveAccent`），外观页那个色块必须画同一档，
    // 否则"选的深灰、界面是浅灰蓝"，对不上号。
    for (final preset in appThemePresets) {
      final light = themeOf(preset.id, Brightness.light).colorScheme;
      final dark = themeOf(preset.id, Brightness.dark).colorScheme;
      expect(
        effectiveAccent(preset.seed, light.surface, Brightness.light),
        preset.seed,
        reason: '浅色下色块应当就是种子原色（「${preset.name}」）',
      );
      expect(
        effectiveAccent(preset.seed, dark.surface, Brightness.dark),
        dark.primary,
        reason: '深色下色块应当等于实际生效的 primary（「${preset.name}」）',
      );
    }
  });

  test('深色：选中胶囊上的字与胶囊淡底对比度 ≥ 3:1', () {
    for (final preset in appThemePresets) {
      final scheme = themeOf(preset.id, Brightness.dark).colorScheme;
      final pill = Color.alphaBlend(
        scheme.secondaryContainer,
        bottomNavColorOf(scheme),
      );
      final ratio = contrastRatio(scheme.onSecondaryContainer, pill);
      expect(
        ratio,
        greaterThanOrEqualTo(3.0),
        reason: '「${preset.name}」选中那一格的字与胶囊只有 '
            '${ratio.toStringAsFixed(2)}:1',
      );
    }
  });

  test('压在强调色上的文字足够醒目（onPrimary 是黑或白，不随主题偏色）', () {
    for (final brightness in Brightness.values) {
      for (final id in <String>['default', 'ink', 'sand', 'pine', 'clay', 'plum', 'ocean']) {
        final scheme = themeOf(id, brightness).colorScheme;
        final on = scheme.onPrimary;
        final r = (on.r * 255).round();
        final g = (on.g * 255).round();
        final b = (on.b * 255).round();
        expect(
          (r == 255 && g == 255 && b == 255) || (r == 26 && g == 26 && b == 26),
          isTrue,
          reason: 'onPrimary 在「$id」/$brightness 下是 rgb=$r,$g,$b，应当是纯黑或纯白',
        );
        // 与强调色的**对比度**要够（WCAG 公式），否则按钮上的字读不清。
        // 用对比度而不是"明度差"：后者对中间调的蓝色会误判
        // （白字压在 #2F6FEB 上明度差只有 0.17，但对比度 4.8 完全够读）。
        final light = <double>[on.computeLuminance(), scheme.primary.computeLuminance()]
          ..sort();
        final ratio = (light[1] + 0.05) / (light[0] + 0.05);
        expect(
          ratio,
          greaterThanOrEqualTo(3.0),
          reason: 'onPrimary 与 primary 的对比度只有 ${ratio.toStringAsFixed(2)}'
              '（$id/$brightness），低于 3:1 就不好读了',
        );
      }
    }
  });

  test('背景色本身是中性灰（R=G=B），不带主题色的色相', () {
    for (final brightness in Brightness.values) {
      final scheme = themeOf('pine', brightness).colorScheme; // 绿主题
      for (final role in <String>['surface', 'surfaceContainerLow', 'surfaceContainerHighest']) {
        final color = roleOf(scheme, role);
        final r = (color.r * 255).round();
        final g = (color.g * 255).round();
        final b = (color.b * 255).round();
        // 允许 1 的取整误差，但不允许明显偏色
        expect(
          (r - g).abs() <= 1 && (g - b).abs() <= 1,
          isTrue,
          reason: '$role 在绿主题下偏色了（rgb=$r,$g,$b），背景必须是中性灰',
        );
      }
    }
  });

  group('中文字体的兜底链', () {
    test('主题带兜底链，且**不设** fontFamily（西文仍走平台默认）', () {
      for (final brightness in Brightness.values) {
        final theme = themeOf('default', brightness);
        expect(theme.textTheme.bodyMedium?.fontFamilyFallback, cjkFontFallback,
            reason: '不设兜底链时，Windows 上中文会落到宋体系（笔画细、有衬线）');
        // 注意：`fontFamily` 不需要（也不该）在这里断言成 null ——
        // 测试环境的平台默认字体是 Roboto，真机 Windows 上是 Segoe UI。
        // 这条只要守住"我们没有**主动**去设一支中文当主字体"即可。
        expect(theme.textTheme.bodyMedium?.fontFamily, anyOf(isNull, 'Roboto'),
            reason: '主动设 fontFamily 会把西文从平台默认上拽走');

        // 兜底链要真的落在**用得到的**那些样式上，而不只是 ThemeData 上的一个字段
        for (final style in <TextStyle?>[
          theme.textTheme.bodyMedium,
          theme.textTheme.titleMedium,
          theme.textTheme.headlineSmall,
          theme.textTheme.labelLarge,
        ]) {
          expect(style?.fontFamilyFallback, cjkFontFallback,
              reason: '${style?.fontSize} 这条样式没吃到兜底链');
        }
      }
    });

    test('兜底链第一支是雅黑，且不重复', () {
      expect(cjkFontFallback.first, 'Microsoft YaHei UI');
      expect(cjkFontFallback.toSet().length, cjkFontFallback.length,
          reason: '有重复项说明这支白列了');
      // 每一支都得是"可能存在的字体名"，空串会变成永远命不中的空档
      for (final family in cjkFontFallback) {
        expect(family.trim(), isNotEmpty);
      }
    });
  });
}
