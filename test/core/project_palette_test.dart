import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/project_palette.dart';

/// 项目 / 事件标识色色板的**可验证约束**（批 B 第 ② 项）。
///
/// 这一组用例回答的不是"好不好看"（那要截图），而是三件能算的事：
///   1. **纯加法**：前 12 个色值一个都没动，新的 4 个只往后接（老数据零迁移）；
///   2. **可辨距离**：任意两色的 CIE76 ΔE **不小于原 12 色里最小的那一对** ——
///      新色不会比原有色更难区分；
///   3. **还是同一套灰调**：新色的 HSL 饱和度 / 明度落在原 12 色的区间内，
///      色相落在四个补齐的语义窗口里。
///
/// 度量写在色板文件的注释里（`lib/core/models/project_palette.dart`），
/// 这里按同一套算法实现：sRGB → 线性 → XYZ(D65) → CIELAB → 欧氏距离。
void main() {
  /// 原 12 色**冻结快照**：改动它 = 破坏"老数据零迁移"，用例就是来挡这个的。
  const List<String> frozen12 = <String>[
    '#AD6868',
    '#B87F56',
    '#DECF7C',
    '#CCE8B6',
    '#87C57E',
    '#87C7AD',
    '#78D2CA',
    '#A9BFD5',
    '#8280AE',
    '#DAC1E0',
    '#A56EA9',
    '#A85780',
  ];

  /// 追加的 4 个：色名 → 色号（顺序即色板里的顺序）。
  const List<String> addedNames = <String>['靛蓝', '橄榄', '咖棕', '青灰（石板）'];

  test('色板是 16 个：前 12 个与冻结快照逐字节相同，新增的 4 个追加在末尾', () {
    expect(ProjectPalette.hexes, hasLength(16));
    expect(
      ProjectPalette.hexes.take(12).toList(),
      frozen12,
      reason: '原有 12 色是"老数据零迁移"的底线：顺序与色值都不许动',
    );
    expect(
      ProjectPalette.hexes.skip(12).toList(),
      hasLength(addedNames.length),
    );
  });

  test('色号格式统一：`#RRGGBB` 大写、无重复', () {
    final pattern = RegExp(r'^#[0-9A-F]{6}$');
    for (final hex in ProjectPalette.hexes) {
      expect(pattern.hasMatch(hex), isTrue, reason: '$hex 不是数据契约里的格式');
    }
    expect(
      ProjectPalette.hexes.toSet(),
      hasLength(ProjectPalette.hexes.length),
      reason: '同一支色出现两次会让"取用得最少的那支"失衡',
    );
  });

  group('可辨距离（CIE76 ΔE，CIELAB / D65）', () {
    test('任意两色（含新旧之间）的 ΔE ≥ 原 12 色里的最小 ΔE', () {
      final threshold = _minPairwiseDeltaE(frozen12);
      final all = _minPairwiseDeltaE(ProjectPalette.hexes);

      // 打印出来方便对账：门槛来自"松石 / 青"那一对
      expect(
        threshold,
        closeTo(11.83, 0.01),
        reason: '原 12 色里最接近的一对（松石 #87C7AD / 青 #78D2CA）就是门槛',
      );
      expect(
        all,
        greaterThanOrEqualTo(threshold - 1e-9),
        reason: '有颜色比原有色更难区分：门槛 $threshold，实际最差的一对只有 $all',
      );
    });

    test('每支新色离最近的原色都还留着一截（不是贴着门槛擦过去）', () {
      for (final hex in ProjectPalette.hexes.skip(12)) {
        final nearest = frozen12
            .map((other) => (other, _deltaE(hex, other)))
            .reduce((a, b) => a.$2 <= b.$2 ? a : b);
        expect(
          nearest.$2,
          greaterThanOrEqualTo(15.0),
          reason: '$hex 离最近的原色 ${nearest.$1} 只有 ΔE ${nearest.$2.toStringAsFixed(2)}',
        );
      }
    });

    test('新色之间也互相区分得开', () {
      final added = ProjectPalette.hexes.skip(12).toList();
      for (var i = 0; i < added.length; i += 1) {
        for (var j = i + 1; j < added.length; j += 1) {
          expect(
            _deltaE(added[i], added[j]),
            greaterThanOrEqualTo(_minPairwiseDeltaE(frozen12) - 1e-9),
            reason: '${added[i]} 与 ${added[j]} 太像',
          );
        }
      }
    });
  });

  group('色系统一：新色仍是同一套灰调', () {
    final baseHsl = frozen12.map(_hsl).toList();
    final minS = baseHsl.map((e) => e.$2).reduce(math.min);
    final maxS = baseHsl.map((e) => e.$2).reduce(math.max);
    final minL = baseHsl.map((e) => e.$3).reduce(math.min);
    final maxL = baseHsl.map((e) => e.$3).reduce(math.max);

    test('饱和度 / 明度落在原 12 色的区间内', () {
      for (final hex in ProjectPalette.hexes.skip(12)) {
        final hsl = _hsl(hex);
        expect(
          hsl.$2,
          inInclusiveRange(minS, maxS),
          reason: '$hex 的饱和度 ${hsl.$2} 跑出了原色区间 [$minS, $maxS]',
        );
        expect(
          hsl.$3,
          inInclusiveRange(minL, maxL),
          reason: '$hex 的明度 ${hsl.$3} 跑出了原色区间 [$minL, $maxL]',
        );
      }
    });

    test('四支新色分别补上靛蓝 / 橄榄 / 咖棕 / 青灰（石板）四段色相', () {
      // 色相窗口按色名取：靛蓝（偏紫的蓝）、橄榄（黄绿）、咖棕（偏红的棕）、
      // 青灰 / 石板（偏青的灰蓝）。窗口宽 12°，只要"是这个色系"就算过。
      const windows = <String, (double, double)>{
        '靛蓝': (222, 240),
        '橄榄': (62, 80),
        '咖棕': (26, 42),
        '青灰（石板）': (196, 212),
      };

      final added = ProjectPalette.hexes.skip(12).toList();
      for (var i = 0; i < added.length; i += 1) {
        final name = addedNames[i];
        final window = windows[name]!;
        final hue = _hsl(added[i]).$1;
        expect(
          hue,
          inInclusiveRange(window.$1, window.$2),
          reason: '$name（${added[i]}）的色相 $hue 不在 ${window.$1}~${window.$2} 里',
        );
      }
    });
  });
}

// ---------------------------------------------------------------- 颜色计算

/// sRGB（`#rrggbb`）→ CIELAB（D65）。
(double, double, double) _lab(String hex) {
  final value = int.parse(hex.substring(1), radix: 16);
  final r = _linear(((value >> 16) & 0xFF) / 255);
  final g = _linear(((value >> 8) & 0xFF) / 255);
  final b = _linear((value & 0xFF) / 255);

  // sRGB → XYZ（D65），再按白点归一
  final x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047;
  final y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
  final z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883;

  final fx = _labF(x);
  final fy = _labF(y);
  final fz = _labF(z);
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

double _linear(double channel) => channel <= 0.04045
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

double _labF(double t) => t > 0.008856
    ? math.pow(t, 1 / 3).toDouble()
    : 7.787 * t + 16 / 116;

/// CIE76 ΔE：Lab 三个分量上的欧氏距离。
double _deltaE(String a, String b) {
  final (l1, a1, b1) = _lab(a);
  final (l2, a2, b2) = _lab(b);
  return math.sqrt(
    math.pow(l1 - l2, 2) + math.pow(a1 - a2, 2) + math.pow(b1 - b2, 2),
  );
}

/// 一组色里**最接近的那一对**的 ΔE —— 它就是"可辨距离"的门槛。
double _minPairwiseDeltaE(List<String> hexes) {
  var worst = double.infinity;
  for (var i = 0; i < hexes.length; i += 1) {
    for (var j = i + 1; j < hexes.length; j += 1) {
      worst = math.min(worst, _deltaE(hexes[i], hexes[j]));
    }
  }
  return worst;
}

/// `#rrggbb` → HSL：`(色相 0~360, 饱和度 0~1, 明度 0~1)`。
(double, double, double) _hsl(String hex) {
  final value = int.parse(hex.substring(1), radix: 16);
  final r = ((value >> 16) & 0xFF) / 255;
  final g = ((value >> 8) & 0xFF) / 255;
  final b = (value & 0xFF) / 255;

  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final lightness = (maxC + minC) / 2;
  final delta = maxC - minC;
  if (delta == 0) return (0, 0, lightness);

  final saturation = delta / (1 - (2 * lightness - 1).abs());
  double hue;
  if (maxC == r) {
    hue = 60 * (((g - b) / delta) % 6);
  } else if (maxC == g) {
    hue = 60 * ((b - r) / delta + 2);
  } else {
    hue = 60 * ((r - g) / delta + 4);
  }
  if (hue < 0) hue += 360;
  return (hue, saturation, lightness);
}
