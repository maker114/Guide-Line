import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 从图片字节里取一个"能当主题种子"的颜色。
///
/// 这是**启发式**的，不追求精确的主色提取：
///   1. 先把图缩到很小（默认 32px）再读像素，代价与图片大小无关；
///   2. 只保留"有颜色"的像素（够饱和、不是死黑死白），按饱和度加权求平均；
///   3. 把结果规整到"够鲜艳但不刺眼"的区间（S 0.35~0.75，L 0.42~0.58）。
///
/// 为什么不直接取"出现次数最多的颜色"：照片里最多的往往是灰墙、阴影和天空，
/// 拿它当主色会得到一片脏灰，做出来的主题还不如默认配色。
Future<Color?> seedColorFromImageBytes(Uint8List bytes, {int sampleSize = 32}) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: sampleSize,
      targetHeight: sampleSize,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;

    final pixels = data.buffer.asUint8List();
    var weightSum = 0.0;
    var rSum = 0.0;
    var gSum = 0.0;
    var bSum = 0.0;

    for (var i = 0; i + 3 < pixels.length; i += 4) {
      if (pixels[i + 3] < 200) continue; // 半透明像素不算数
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
      if (hsl.saturation < 0.15) continue; // 灰
      if (hsl.lightness < 0.12 || hsl.lightness > 0.92) continue; // 死黑 / 死白

      // 越鲜艳、越接近中等亮度，权重越高
      final midness = (1 - (hsl.lightness - 0.5).abs() * 1.6).clamp(0.15, 1.0);
      final weight = hsl.saturation * hsl.saturation * midness;
      weightSum += weight;
      rSum += r * weight;
      gSum += g * weight;
      bSum += b * weight;
    }

    if (weightSum <= 0) return null;

    final averaged = Color.fromARGB(
      255,
      (rSum / weightSum).round().clamp(0, 255),
      (gSum / weightSum).round().clamp(0, 255),
      (bSum / weightSum).round().clamp(0, 255),
    );
    final hsl = HSLColor.fromColor(averaged);
    return hsl
        .withSaturation(math.max(0.35, math.min(0.75, hsl.saturation)))
        .withLightness(math.max(0.42, math.min(0.58, hsl.lightness)))
        .toColor();
  } catch (_) {
    // 解不出来就当没有取到色 —— 主题退回默认，绝不能因此崩掉
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
