import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/platform/shortcut_channel.dart';

/// `ShortcutChannel` 的**降级路径**（T-7）：通道不存在时必须当成"没有速记请求"。
///
/// 这条路径在真机上对应桌面调试 / 非 Android 平台 / 单元测试环境 ——
/// 而它在审计时是**零覆盖**的。降级写错（比如让它抛出去）会让 App 在
/// "长按图标进来"这条路上直接崩，而这恰恰是最常被忽略的入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('通道不存在时：consumePendingCapture 返回 false 而不是抛错', () async {
    // 测试环境里没有原生实现，所以走的正是 MissingPluginException 那条路
    final pending = await ShortcutChannel.consumePendingCapture();
    expect(pending, isFalse, reason: '拿不到就当作"这次不是冲着速记来的"');
  });

  test('注册回调本身不该抛错（热启动那条路）', () {
    var called = 0;
    expect(
      () => ShortcutChannel.onCapture(() => called += 1),
      returnsNormally,
      reason: '没有原生实现时注册回调也要安全；真实调用由原生侧发起',
    );
    expect(called, 0, reason: '没人推事件就不该被调用');
  });
}
