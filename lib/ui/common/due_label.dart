import 'package:flutter/material.dart';

import 'format.dart';

/// 到期日怎么写：**全应用唯一出处**（《界面规范》§7 的数量/文案口径）。
///
/// 默认是「绝对日期 + 剩余天数」（`2026-09-30（3 天后）`）——
/// 只给相对日不知道到底是几号，只给绝对日期又看不出还剩几天，
/// 两个都给才回答得了"什么时候到期、还剩多少"。
///
/// 但一行里还要放缩进、状态圆圈与图标：放不下时**按宽度降级**成「3 天后」——
/// 两种写法都带着"还剩几天"，最有用的信息不会丢。
///
/// 用屏幕宽度而不是 `LayoutBuilder`：`ListTile` 在**量高度**时给副标题的
/// `maxWidth` 是 `Infinity`（本项目踩过这个坑），那里量不出真实宽度。
///
/// [reservedWidth] 是"这一行**除日期文字以外**必须占掉"的宽度。
///
/// ⚠️ **这个数不许再拍脑袋给**（2026-10-04 修）。原先三处分别写 200 / 240 / 300，
/// 注释里自己写着"估"—— 而真机实测下来，事件页那一行除日期以外只占 **≈74dp**
/// （见 [dueRowReservedWidth] 里那份量法）：等于白白扔掉 170dp，
/// 于是**明明还剩一半空着的行也被截成短句**。带时刻的
/// （`2026-10-01 18:00（逾期 3 天）`，比不带时刻的长约 40dp）更是必截 ——
/// 用户实机看到的就是"一条条长的长短的短、毫无规律"。
String dueLabelOf(
  BuildContext context,
  String? dueAt, {
  double reservedWidth = dueRowReservedWidth,
  DateTime? now,
}) {
  if (dueAt == null || dueAt.isEmpty) return '';

  final full = describeDateWithDays(dueAt, now: now);
  if (labelWidthOf(context, full) + reservedWidth <= MediaQuery.sizeOf(context).width) {
    return full;
  }
  return describeDate(dueAt, now: now);
}

/// 任务行里**除日期文字以外真的占掉多少**。
///
/// 2026-10-04 从真机截图量出来的（小米 15 Pro，1080px 宽 / 450dpi ⇒ 逻辑宽 384dp，
/// 1dp = 2.8125px）：到期日那一行的最左墨迹落在 **54dp**（行缩进 + 状态圆圈 + 间距），
/// 那之后是日历图标 **13dp** 与间距 **3dp**，右边还有 **4dp** 内边距 —— 合计 ≈74dp。
///
/// 这里取 **100dp**：多出来的约 26dp 是留给"代码里量的宽度"与"屏幕上真渲染的宽度"
/// 之间那点差的（字体回退、抗锯齿）。宁可少留一点，也不要再回到"还剩 180dp
/// 空着却被截"那种状态；真到了 1.6 倍字体那样挤不下的时候，它自然会退成短句 ——
/// 那才是这条降级该出现的时候。
const double dueRowReservedWidth = 100;

/// 量一段 `labelSmall` 文字有多宽 —— 与 [dueLabelOf] **同一把尺子**。
///
/// 抽出来是给"这一行除日期以外还有别的东西"的地方用的：最典型的是事件详情页
/// 那种「今天　下级 0/7」—— 那时预留宽度必须**把「下级 x/y」的实际宽度加进去**，
/// 而不是再拍一个 300（原先就是拍出来的，于是"有子任务"的行一律被截成短句）。
double labelWidthOf(BuildContext context, String text) {
  final style = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
  return (TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout())
      .width;
}
