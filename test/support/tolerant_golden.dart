import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 容差 golden 比较器：**照旧逐像素比，但允许一小撮像素不同**。
///
/// ## 为什么需要它（2026-10-06 实测）
///
/// `matchesGoldenFile` 默认用 `LocalFileComparator`，要求两张图**逐像素完全一致**
/// —— 它守的是"屏幕上到底长什么样"，这是全仓最强的一条断言：尺寸、语义、颜色函数
/// 全都可能"算对了但没画上去"，只有它拦得住。
///
/// 但它钉的是**字节**，于是凡是不影响"对不对"、只影响"哪台机器渲染"的东西
/// （抗锯齿策略、字形栅格化、Skia 版本）都会让它红。实测证据：CI（ubuntu）
/// 与本机（Windows）跑同一段代码，
///
/// ```
/// Golden "goldens/sync_indicator_done.png": Pixel test failed, 0.08%, 363px diff detected.
/// ```
///
/// —— **0.08%（363 个像素）**，肉眼不可见，却足以让整条测试红。而基准图只能
/// 是某一个平台生成的，所以这条断言**跨平台不可能同时成立**。
///
/// 更坏的还不是这条红，而是它会**训练人忽略红**：一条永远红、又与代码正确性
/// 无关的检查，和将来真出问题时的样子一模一样。
///
/// ## 容差为什么是 0.5%
///
/// 实测跨平台噪声 0.08% ⇒ 留 **6 倍**余量。而真正的回归 ——
/// "整格透明"（约 100%）、"颜色画错"、"形状挪位" —— 都远远超过这个预算，
/// 照样会红。超预算时**退回父类那一套**（写出差异图 + 标准报错文案），
/// 所以排查体验一点没变。
class TolerantGoldenComparator extends LocalFileComparator {
  TolerantGoldenComparator(super.basedir, {this.maxDiffRatio = 0.005});

  /// 允许不同的像素占比上限；超过就按父类报错。
  final double maxDiffRatio;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    // 路径自己算（`basedir` 是父类的公开字段）：不碰 `getGoldenFile` ——
    // 它在不同 Flutter 版本上同步/异步来回改过，**这个仓库吃过那个亏**。
    //
    // ⚠️ 别自己造 `basedir`：调用方应当**接管默认比较器那一份**
    // （`(goldenFileComparator as LocalFileComparator).basedir`）。
    // 自己拼路径错过两次：`Uri.file()` 会吞掉 `test/`；`Directory.current.uri`
    // 在测试配置里拿到的还是包根目录。
    final File goldenFile = File.fromUri(basedir.resolveUri(golden));
    if (!goldenFile.existsSync()) {
      throw TestFailure(
        '基准图不存在：$goldenFile\n'
        '  basedir = $basedir\n'
        '  key     = $golden\n'
        '（key 按"相对 basedir"解析；basedir 应当来自默认比较器）',
      );
    }

    final Uint8List? got = await _rgba(imageBytes);
    final Uint8List? want = await _rgba(goldenFile.readAsBytesSync());
    if (got == null || want == null || got.length != want.length) {
      // 解不出来、或尺寸都不一样（那是结构性变化，不该被容差放过）
      return super.compare(imageBytes, golden);
    }

    final int total = got.length ~/ 4;
    int diff = 0;
    for (int i = 0; i < got.length; i += 4) {
      if (got[i] != want[i] ||
          got[i + 1] != want[i + 1] ||
          got[i + 2] != want[i + 2] ||
          got[i + 3] != want[i + 3]) {
        diff++;
      }
    }
    if (diff / total <= maxDiffRatio) return true;

    // 超出容差：走父类，写出 `*_testImage.png` / `*_maskedDiff.png` 供人看
    return super.compare(imageBytes, golden);
  }

  /// 把 PNG 解成 RGBA 字节；解不出来返回 null。
  Future<Uint8List?> _rgba(Uint8List png) async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(png);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ByteData? data =
          await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
