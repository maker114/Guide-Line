import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/ui_prefs.dart';
import 'package:guideline/ui/theme/app_theme.dart';

/// 归档区「已处理的灵感」里三种来源的小胶囊，颜色必须**互相看得出来**
/// （实机反馈："不同类型的灵感下的小标签用不同颜色表示"）。
///
/// 它同时是一条**选色约束**，实测出来的：这套配色由单一 seed 推导，
/// `secondaryContainer` / `tertiaryContainer` / `primaryContainer`
/// **就是同一个值**（两两 RGB 距离恒为 0），所以三档只能落在
/// 「primary 档 / error 档 / 中性底」这三个真正不同的家族上。
/// 改配色或改 `_SourceChip` 时先看这里红不红。
void main() {
  double distance(Color a, Color b) {
    final dr = (a.r - b.r) * 255;
    final dg = (a.g - b.g) * 255;
    final db = (a.b - b.b) * 255;
    return math.sqrt(dr * dr + dg * dg + db * db);
  }

  for (final themeId in <String>['default', 'ink', 'sand', 'pine', 'plum']) {
    for (final brightness in Brightness.values) {
      final label = brightness == Brightness.dark ? '深色' : '浅色';
      test('$themeId/$label：被隐藏 / 已丢弃 / 已合并 三色互相分得开', () {
        final scheme = buildAppTheme(
          UiPrefs(themeId: themeId),
          brightness,
        ).colorScheme;

        final hidden = scheme.surface;
        final discarded = scheme.errorContainer;
        final merged = scheme.primaryContainer;

        // 两条底线分开写，因为它们挡的不是同一件事：
        //   · 主次两档（已丢弃 / 已合并）必须**明显**不同 —— 大于 100；
        //   · 中性那档（被隐藏）与它们拉开即可 —— 大于 25。
        // 为什么后者只有 25：本调色板的容器色都挤在浅灰一带，中性底与
        // `errorContainer` 在浅色主题下天然只差 36。要更强只能往
        // 「主题里加三条固定色」（像 `UrgencyColors` 那样）走，那是一次
        // 配色层面的决定，不在这一条里擅自做。
        expect(
          distance(discarded, merged),
          greaterThan(100),
          reason: '「已丢弃」与「已合并」必须一眼分得开（$themeId/$label）',
        );
        expect(
          distance(hidden, discarded),
          greaterThan(25),
          reason: '「被隐藏」与「已丢弃」在 $themeId/$label 下粘在一起了',
        );
        expect(
          distance(hidden, merged),
          greaterThan(25),
          reason: '「被隐藏」与「已合并」在 $themeId/$label 下粘在一起了',
        );
      });
    }
  }
}
