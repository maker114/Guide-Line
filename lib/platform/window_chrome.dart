import 'dart:io';

import 'package:flutter/services.dart';

/// 无边框窗口的窗口按钮（最小化 / 最大化切换 / 关闭）。
///
/// 电脑端把原生标题栏收掉了（`windows/runner/win32_window.cpp` 的 `WM_NCCALCSIZE`），
/// 于是最小化 / 关闭这些动作只剩两条路：系统菜单（Alt+Space、右键标题栏）或
/// 界面上的按钮。这一层就是后者的通道：Flutter 只发三个方法名，真正执行在
/// `windows/runner/flutter_window.cpp`。
///
/// 非 Windows 平台上是空操作 —— 手机 / 平板不会走到桌面外壳的按钮，
/// 但这一层被 import 时不该炸。
class WindowChrome {
  const WindowChrome._();

  static const MethodChannel _channel = MethodChannel('guideline/window');

  /// 是不是走原生窗口按钮的平台（只有 Windows 有这条通道）。
  static bool get supported => Platform.isWindows;

  static Future<void> minimize() => _invoke('minimize');

  static Future<void> maximizeRestore() => _invoke('maximizeRestore');

  static Future<void> close() => _invoke('close');

  static Future<bool> isMaximized() async {
    if (!supported) return false;
    try {
      final value = await _channel.invokeMethod<bool>('isMaximized');
      return value ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> _invoke(String method) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // 没有通道（例如用 `flutter test` 跑桌面外壳）时静默跳过：
      // 按钮的语义不该因为跑测试就崩。
    }
  }
}
