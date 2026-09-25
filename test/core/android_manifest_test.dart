import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 发布包必须真的有**联网权限**。
///
/// 这是一次真实故障的守护：Flutter 模板只在 `debug` / `profile` 清单里写
/// `android.permission.INTERNET`（那是给热重载用的），主清单里没有。
/// 于是出现了最难查的一类现象 —— **调试时能连上、装出来的 release 包连不上**，
/// 而且 Dart 侧只报一个笼统的 SocketException，完全看不出是权限问题。
///
/// 从「AI 整理」开始这个应用要自己发请求，所以这条权限必须在主清单里。
/// 这个测试扫源码（和架构边界测试同一套路数），不需要真机或打包。
void main() {
  test('主清单声明了 INTERNET 权限（release 包不继承 debug 的权限）', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml');
    expect(manifest.existsSync(), isTrue, reason: '主清单路径变了？');

    final text = manifest.readAsStringSync();
    expect(
      text,
      contains('android.permission.INTERNET'),
      reason: '没有这条，release 包在 Android 上不允许任何网络访问；'
          '而 debug 清单里有，会让"调试正常、发布不行"',
    );
  });

  test('debug / profile 清单里的那条不算数（它们是给热重载用的）', () {
    // 这个断言是在说明"为什么不能只靠 debug 清单"：连它们在哪也说清楚，
    // 免得后来的人看到 debug 清单里有就以为够了。
    for (final variant in <String>['debug', 'profile']) {
      final file = File('android/app/src/$variant/AndroidManifest.xml');
      if (!file.existsSync()) continue;
      expect(
        file.readAsStringSync(),
        contains('android.permission.INTERNET'),
        reason: '$variant 清单在 Flutter 模板里本来就带这条，用来热重载',
      );
    }
  });
}
