import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 背景图层（**实验性**）。
///
/// 放在 `MaterialApp.builder` 里，垫在整个应用下面；真正让它显出来的是
/// `buildAppTheme` 在启用背景图时把 `scaffoldBackgroundColor` 与 AppBar 底色
/// 改成半透明的 surface —— 这样不用往任何页面里塞"透明背景"的补丁，
/// 文字对比度也仍由主题控制。
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.bytes,
    required this.opacity,
    required this.blur,
    required this.child,
  });

  final Uint8List? bytes;
  final double opacity;
  final double blur;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    if (data == null) return child;

    Widget image = Image.memory(
      data,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // 背景只是装饰，读不出来就当作没有，不要让整页报错
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );

    if (blur > 0) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: image,
      );
      // 模糊会把四周糊出去一圈，放大一点避免露出边缘
      image = Transform.scale(scale: 1.15, child: image);
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ExcludeSemantics(
          child: IgnorePointer(
            child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: image),
          ),
        ),
        child,
      ],
    );
  }
}
