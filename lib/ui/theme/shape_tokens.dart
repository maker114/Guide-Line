import 'package:flutter/material.dart';

/// 全应用的形状 token（《界面规范》§2）。
///
/// 规则一句话：**能点的用胶囊，装东西的用圆角矩形，只有图标的用正圆。**
///
/// 为什么要有这个文件：改之前圆角是**逐处写死的** `BorderRadius.circular(12)`，
/// 想统一观感就得翻遍所有控件，而且很容易改一半留一半。这里按**用途**命名而不是
/// 按数值命名 —— 以后调整半径只改这一处，调用点不用动。
///
/// 三条不要做的事：
///   · 不要在控件里再写 `BorderRadius.circular(n)` 字面量；
///   · 不要给整行容器（`ListTile`、页面底）加圆角 —— 圆角里套圆角会显脏；
///   · 不要把危险动作（删除 / 归档）做成醒目的胶囊按钮。
abstract final class AppShapes {
  /// 胶囊：按钮、输入框、导航条、状态标签。
  static const StadiumBorder pill = StadiumBorder();

  /// 正圆：纯图标按钮、色点、头像。
  static const CircleBorder circle = CircleBorder();

  /// 内容卡片、任务框、多行书写区。
  ///
  /// 参考图里的卡片半径目测约占卡高的 1/4；落地到手机宽度取 20 比较稳。
  static const RoundedRectangleBorder card = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(cardRadius)),
  );

  /// 卡片内的方形快选块（参考图的「拍照 / 照片 / 本地文件」）。
  static const RoundedRectangleBorder chip = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(chipRadius)),
  );

  /// 卡片内的小字段 / 值标签底。
  static const RoundedRectangleBorder field = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
  );

  /// 卡片里的次级块。
  ///
  /// 保留 `12` 是因为**现有代码已经在用这个值**（任务框、背景图强度预览），
  /// 把它留成单独一档，免得为了"统一"反而把卡片内外的层级压平。
  static const RoundedRectangleBorder nested = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(nestedRadius)),
  );

  /// 徽标、色块这类小东西。
  static const RoundedRectangleBorder badge = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );

  /// 对话框（与 Material 3 默认值对齐）。
  static const RoundedRectangleBorder dialog = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(28)),
  );

  /// 底部弹出面板：**只圆上面两个角**。
  ///
  /// 参考图里面板贴着屏幕底边，下缘是直角；给它四个角都加圆角会跟屏幕边留出缝隙。
  static const RoundedRectangleBorder sheet = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(sheetRadius)),
  );

  /// 圆角半径的"只取数值"版本，给需要自己拼 `BorderRadius` 的地方用
  /// （例如只圆某一边、或给 `Container` 的 `decoration` 用）。
  static const double cardRadius = 20;

  /// 卡片内快选块的半径（`chip` 用的就是它）。
  static const double chipRadius = 16;

  static const double sheetRadius = 28;

  static const double nestedRadius = 12;

  /// 胶囊的等效半径：给**必须用 `BorderRadius` 而不能用 `StadiumBorder`** 的地方用
  /// （`OutlineInputBorder` 只接受 `BorderRadius`，不接 `StadiumBorder`）。
  /// 取一个明显大于输入框高度的值，效果就是胶囊两端。
  static const double pillRadius = 24;

  /// 只圆上缘的半径（底部面板用）。
  static const BorderRadius topOnly = BorderRadius.vertical(
    top: Radius.circular(sheetRadius),
  );
}
