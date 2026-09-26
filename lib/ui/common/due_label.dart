import 'package:flutter/material.dart';

import 'format.dart';

/// 到期日怎么写：**全应用唯一出处**（《界面规范》§7 的数量/文案口径）。
///
/// 默认是「绝对日期 + 剩余天数」（`2026-09-30（3 天后）`）——
/// 只给相对日不知道到底是几号，只给绝对日期又看不出还剩几天，
/// 两个都给才回答得了"什么时候到期、还剩多少"。
///
/// 但任务行里还要放事件名与完成钮：实测 1.6 倍字体、360dp 宽时，
/// 那串全称一个人就要 240dp，会把事件名挤没。所以**按宽度降级**：
/// 放得下用全称，放不下退成「3 天后」——两种写法都带着"还剩几天"，
/// 最有用的信息不会丢。
///
/// 用屏幕宽度而不是 `LayoutBuilder`：`ListTile` 在**量高度**时给副标题的
/// `maxWidth` 是 `Infinity`（本项目踩过这个坑），那里量不出真实宽度。
///
/// [reservedWidth] 是"这一行除日期以外必须占掉"的宽度，由调用方按所处位置估
/// （列表行 ≈ 200，事件卡里带缩进 ≈ 240，详情页节点还要放「下级 x/y」≈ 300）。
String dueLabelOf(
  BuildContext context,
  String? dueAt, {
  double reservedWidth = 200,
}) {
  if (dueAt == null || dueAt.isEmpty) return '';

  final style = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
  final scaler = MediaQuery.textScalerOf(context);
  double widthOf(String text) => (TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout())
          .width;

  final full = describeDateWithDays(dueAt);
  if (widthOf(full) + reservedWidth <= MediaQuery.sizeOf(context).width) {
    return full;
  }
  return describeDate(dueAt);
}
