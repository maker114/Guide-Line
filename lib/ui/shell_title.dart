import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 标题栏翻页过渡的**横向位移幅度**（dp）。
///
/// **原值 10 → 新值 18（2026-09-26 批 D 第 ① 项）**。为什么要加：10 那一版
/// 实机反馈"拖动切页时标题还是显得硬切"—— 位移那一档与底栏滑块挪出去的量相比
/// 太小，两层叠在一起时看着像没动。18 是"看得出方向"的上限，再大就像在滑一列字。
///
/// 位移与透明度都只由**连续页位置的小数部分**决定（见 [shellTitleFade]）——
/// 拖到一半再拖回来，标题按同一个公式回到原样（不存在"必须靠动画补回来"的状态）。
const double shellTitleShift = 18;

/// 翻页过渡的**形状**：smoothstep `t²(3 − 2t)`。
///
/// **线性 → smoothstep（2026-09-26 批 D 第 ① 项）**。原来是线性的 `t`：
/// 两层各按 `t` 与 `1 − t` 叠着，中间那一段两个标题同时有接近一半的浓度，
/// 实机看着"略微糊"。smoothstep 两头平、中间陡（在 0 与 1 处导数为 0）：
/// 刚起步、快到位时都把主导权更干脆地交给其中一层，"两层都看得见"的区间
/// 明显变短，换页就显得利落；中点仍然各半，不偏袒任何一侧。
///
/// 位移**与不透明度共用这一个数**：`dx` 与 `opacity` 于是永远互补，
/// 拖回来是原样倒放，落位时也天然收干净。
double shellTitleFade(double t) {
  final x = t.clamp(0.0, 1.0);
  return x * x * (3 - 2 * x);
}

/// 翻页过渡中某一页标题所在**图层**的 Key。
///
/// 页位置落在整数上时只建一个 `Text`，任何图层 key 都不该存在 ——
/// 用例靠"找不到图层 key"来钉住"静止时不留动画痕迹"。
@visibleForTesting
Key shellTitleLayerKey(int index) => Key('ShellTitle.layer.$index');

/// 标题栏：跟着页面的**连续位置**交叉淡入淡出 + 轻微横移。
///
/// 改之前标题读的是整数页号（跨过一半才换一次），而底栏的滑块已经跟着连续
/// 页位置走 —— 两者节奏不一致，拖动切页时标题是"啪"地换掉，看着硬。
///
/// 现在的分工：
///   · **位置**由外层的 `PageController` 进度给（左右滑动时跟手指；点按切换时
///     跟着 `animateToPage` 的曲线与时长）—— 标题与页面、底栏于是天然同一条节奏；
///   · **映射**只看 [page] 当前这个数、**不看历史**：旧标题朝运动方向淡出、
///     新标题从反方向淡入，拖回去就是原样倒放。
///
/// **不要**在 `onPageChanged` 里再 `setState` 覆盖它：那个回调跨过半页才来一次，
/// 一旦用它驱动标题，就又退回"整数页号切换"了。
class ShellTitle extends StatelessWidget {
  const ShellTitle({
    super.key,
    required this.page,
    required this.titleAt,
    this.pageCount = 4,
  });

  /// 连续页位置（`1.5` = 项目与事件之间）。
  final ValueListenable<double> page;

  /// 第 [index] 页此刻的标题。
  ///
  /// 是函数而不是字符串列表：项目页 / 事件页的标题带数量，数量会随数据变，
  /// 得在每次重建时按**各自那一页**的口径现算（见 `_AppShellState._titleAt`）。
  final String Function(int index) titleAt;

  /// 一共有几页（用来夹住页位置）。
  final int pageCount;

  /// 落到整数页的**容差**：浮点除法的尾巴（例如 `0.9999999`）不该被当成
  /// "还在两页之间"，否则静止时会多留一个透明的标题层。
  /// 万分之一页 ≈ 0.05dp，肉眼与像素都到不了。
  static const double _epsilon = 1e-3;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: page,
      builder: (context, raw, _) {
        final value = raw.clamp(0.0, (pageCount - 1).toDouble());

        // 无障碍：系统关掉动画时**不做位移**，直接切到离得最近的那一页标题。
        if (MediaQuery.disableAnimationsOf(context)) {
          return Text(titleAt(value.round()));
        }

        final lower = value.floor();
        final upper = value.ceil();
        final t = value - lower;
        // 停在整数上：只画当前这一页，不留任何动画痕迹
        if (upper == lower || t < _epsilon) return Text(titleAt(lower));
        if (t > 1 - _epsilon) return Text(titleAt(upper));

        // 位移与不透明度**共用**这一个数（smoothstep）：
        // 两层的不透明度仍然互补，位移也仍然与它一一对应（见 [shellTitleFade]）
        final fade = shellTitleFade(t);

        return Stack(
          // 两层都要往原位旁边挪最多 18dp，默认的裁剪会把挪出去的那一侧切掉
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: <Widget>[
            // 低页码那一层：页位置靠近它时完全不透明、贴着左端
            _layer(lower, opacity: 1 - fade, dx: -shellTitleShift * fade),
            // 高页码那一层：从右侧 18dp 处淡入
            _layer(upper, opacity: fade, dx: shellTitleShift * (1 - fade)),
          ],
        );
      },
    );
  }

  Widget _layer(int index, {required double opacity, required double dx}) {
    return KeyedSubtree(
      key: shellTitleLayerKey(index),
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        // 位移只走绘制、不参与布局：标题栏的宽度不该被这一下带得忽宽忽窄
        // （标题在 `AppBar` 里是左对齐的，右边多出来的空白不影响别的元素）
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: Text(titleAt(index)),
        ),
      ),
    );
  }
}
