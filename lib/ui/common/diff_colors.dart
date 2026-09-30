import 'package:flutter/material.dart';

import '../../core/store/store_diff.dart';

/// 版本差异的配色（**放在主题里**，见 `app_theme.dart` 的注册）。
///
/// 这几对颜色不能散在控件里：浅色主题下要够深才能在浅底上压住字，
/// 深色主题下反过来得够亮，一套常量在两种主题里必然有一套难看清。
/// 这里只定义每一类差异**该长什么样**，"哪一行是哪一类"由 `DiffKind` / `DiffSide` 决定。
///
/// 口径（2026-09-30 改定，需求③）：**三色**
///   · 绿 = 新增（下个版本才有）· 红 = 删除（上个版本才有）
///   · **黄 = 修改**（两边都有、内容不同）
/// 用户撤回了原先的"改动也是一红一绿"：红绿留给真正动条数的动作，
/// 于是"多了、少了、还是只是改了"一眼分得开。
/// 黄这一对同时给右上角那枚"没传上去"的胶囊用（同步状态只有"提醒"和"失败"两种语气，
/// 见 `sync_status_indicator.dart`），所以它叫 [modifiedBackground] 但不止服务修改。
@immutable
class DiffColors extends ThemeExtension<DiffColors> {
  const DiffColors({
    required this.addedBackground,
    required this.addedForeground,
    required this.removedBackground,
    required this.removedForeground,
    required this.modifiedBackground,
    required this.modifiedForeground,
  });

  /// 下个版本独有的（新增）—— 绿。
  final Color addedBackground;
  final Color addedForeground;

  /// 上个版本独有的（删除）—— 红。
  final Color removedBackground;
  final Color removedForeground;

  /// 两边都有但内容不同（修改）—— 黄。
  final Color modifiedBackground;
  final Color modifiedForeground;

  static const DiffColors light = DiffColors(
    addedBackground: Color(0xFFE4F3E7),
    addedForeground: Color(0xFF1B5E20),
    removedBackground: Color(0xFFFBE4E2),
    removedForeground: Color(0xFF9E2A20),
    modifiedBackground: Color(0xFFFFF3D1),
    modifiedForeground: Color(0xFF7A5300),
  );

  static const DiffColors dark = DiffColors(
    addedBackground: Color(0xFF17301E),
    addedForeground: Color(0xFF93D7A6),
    removedBackground: Color(0xFF3A1D1A),
    removedForeground: Color(0xFFFFB0A7),
    modifiedBackground: Color(0xFF3A2E12),
    modifiedForeground: Color(0xFFFFD479),
  );

  /// 某一类差异要用哪张脸 —— **行底色按这个来**（`DiffKind` 说"是哪一类差异"）。
  Color backgroundOfKind(DiffKind kind) => switch (kind) {
        DiffKind.added => addedBackground,
        DiffKind.removed => removedBackground,
        DiffKind.modified => modifiedBackground,
      };

  Color foregroundOfKind(DiffKind kind) => switch (kind) {
        DiffKind.added => addedForeground,
        DiffKind.removed => removedForeground,
        DiffKind.modified => modifiedForeground,
      };

  /// 某一侧要用哪张脸 —— 图例里那两个"上个版本 / 下个版本"的小方块用它。
  ///
  /// 注意它**答不了"修改是什么颜色"**：同一条改动的记录在两侧都会出现，
  /// 按侧取色就成了一红一绿 —— 那正是被撤回的旧口径。行底色请用
  /// [backgroundOfKind]。
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
    Color? modifiedBackground,
    Color? modifiedForeground,
  }) =>
      DiffColors(
        addedBackground: addedBackground ?? this.addedBackground,
        addedForeground: addedForeground ?? this.addedForeground,
        removedBackground: removedBackground ?? this.removedBackground,
        removedForeground: removedForeground ?? this.removedForeground,
        modifiedBackground: modifiedBackground ?? this.modifiedBackground,
        modifiedForeground: modifiedForeground ?? this.modifiedForeground,
      );

  @override
  DiffColors lerp(ThemeExtension<DiffColors>? other, double t) {
    if (other is! DiffColors) return this;
    return DiffColors(
      addedBackground: Color.lerp(addedBackground, other.addedBackground, t)!,
      addedForeground: Color.lerp(addedForeground, other.addedForeground, t)!,
      removedBackground: Color.lerp(removedBackground, other.removedBackground, t)!,
      removedForeground: Color.lerp(removedForeground, other.removedForeground, t)!,
      modifiedBackground: Color.lerp(modifiedBackground, other.modifiedBackground, t)!,
      modifiedForeground: Color.lerp(modifiedForeground, other.modifiedForeground, t)!,
    );
  }
}
