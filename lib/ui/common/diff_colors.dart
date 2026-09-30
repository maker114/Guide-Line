import 'package:flutter/material.dart';

import '../../core/store/store_diff.dart';

/// 版本差异的配色（**放在主题里**，见 `app_theme.dart` 的注册）。
///
/// 红绿这对颜色不能散在控件里：浅色主题下要够深才能在浅底上压住字，
/// 深色主题下反过来得够亮，一套常量在两种主题里必然有一套难看清。
/// 这里只定义这一处差异**该长什么样**，"哪一行是哪一色"由 `DiffSide` 决定。
///
/// 口径（2026-09-30 定）：**和 git 一样** —— 红的是上个版本、绿的是下个版本；
/// 一处"修改"就是一对红绿相邻，没有第三种颜色（用户明确取消了黄色）。
@immutable
class DiffColors extends ThemeExtension<DiffColors> {
  const DiffColors({
    required this.addedBackground,
    required this.addedForeground,
    required this.removedBackground,
    required this.removedForeground,
  });

  /// 下个版本独有的（新增）—— 绿。
  final Color addedBackground;
  final Color addedForeground;

  /// 上个版本独有的（删除）—— 红。
  final Color removedBackground;
  final Color removedForeground;

  static const DiffColors light = DiffColors(
    addedBackground: Color(0xFFE4F3E7),
    addedForeground: Color(0xFF1B5E20),
    removedBackground: Color(0xFFFBE4E2),
    removedForeground: Color(0xFF9E2A20),
  );

  static const DiffColors dark = DiffColors(
    addedBackground: Color(0xFF17301E),
    addedForeground: Color(0xFF93D7A6),
    removedBackground: Color(0xFF3A1D1A),
    removedForeground: Color(0xFFFFB0A7),
  );

  /// 某一侧要用哪张脸：底色 + 前景（文字/图标）色。
  Color backgroundOf(DiffSide side) =>
      side == DiffSide.next ? addedBackground : removedBackground;

  Color foregroundOf(DiffSide side) =>
      side == DiffSide.next ? addedForeground : removedForeground;

  /// 从当前主题取；主题没注册时退回浅色那套（不该发生，但别让界面崩）。
  static DiffColors ofContext(BuildContext context) =>
      Theme.of(context).extension<DiffColors>() ?? light;

  @override
  DiffColors copyWith({
    Color? addedBackground,
    Color? addedForeground,
    Color? removedBackground,
    Color? removedForeground,
  }) =>
      DiffColors(
        addedBackground: addedBackground ?? this.addedBackground,
        addedForeground: addedForeground ?? this.addedForeground,
        removedBackground: removedBackground ?? this.removedBackground,
        removedForeground: removedForeground ?? this.removedForeground,
      );

  @override
  DiffColors lerp(ThemeExtension<DiffColors>? other, double t) {
    if (other is! DiffColors) return this;
    return DiffColors(
      addedBackground: Color.lerp(addedBackground, other.addedBackground, t)!,
      addedForeground: Color.lerp(addedForeground, other.addedForeground, t)!,
      removedBackground: Color.lerp(removedBackground, other.removedBackground, t)!,
      removedForeground: Color.lerp(removedForeground, other.removedForeground, t)!,
    );
  }
}
