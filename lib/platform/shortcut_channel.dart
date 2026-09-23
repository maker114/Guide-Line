import 'package:flutter/services.dart';

/// 平台适配层：**长按桌面图标 → 速记** 的原生事件通道。
///
/// 原生侧（`android/app/src/main/kotlin/com/maker/guideline/MainActivity.kt`）
/// 把 Android App Shortcut 的 Intent 转成两个入口，覆盖两种启动方式：
///   · [consumePendingCapture]：冷启动时问一次"这次启动是冲着速记来的吗"；
///   · [onCapture]：App 已在后台时直接推事件。
///
/// 通道不存在时（桌面调试、单元测试、其它平台）一律降级为"没有速记请求"，绝不抛错。
class ShortcutChannel {
  const ShortcutChannel._();

  static const MethodChannel _channel = MethodChannel('guideline/shortcut');

  /// 冷启动：取走并清空"本次由速记快捷方式启动"的标记。
  static Future<bool> consumePendingCapture() async {
    try {
      final pending = await _channel.invokeMethod<bool>('consumePendingCapture');
      return pending ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 热启动：注册回调（后注册的覆盖先注册的）。
  static void onCapture(void Function() handler) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onCapture') handler();
      return null;
    });
  }
}
