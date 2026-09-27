import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **发布包的签名接线**（S-4）。
///
/// 原来 `build.gradle.kts` 把 release 写死成 debug 签名（Flutter 模板默认），
/// 于是"换正式签名"还得先改 gradle —— 而换签名是有时间压力的事
/// （签名不同 → 已装用户必须先卸载 → 私有目录数据一起没）。
/// 现在它读 `android/key.properties`、没有就回退 debug，这个接线本身值得守住：
/// 一旦被谁改回写死，这条测试会红。
void main() {
  final gradle = File('android/app/build.gradle.kts');

  test('release 签名读 key.properties，缺失时回退 debug', () {
    expect(gradle.existsSync(), isTrue, reason: 'app 模块的 gradle 脚本被移走了？');
    final text = gradle.readAsStringSync();

    expect(text, contains('rootProject.file("key.properties")'),
        reason: '要去找那块钥匙文件');
    expect(text, contains('hasReleaseKey'), reason: '有没有钥匙要是一个显式判断');
    expect(
      text,
      contains('signingConfigs.getByName("release")'),
      reason: '有 key.properties 时必须用正式签名 —— 否则放进去也不生效',
    );
    expect(
      text,
      contains('signingConfigs.getByName("debug")'),
      reason: '没有 key.properties 时要回退 debug，保证 `flutter run --release` 照旧可用',
    );
  });

  test('key.properties 与 keystore 都不入库', () {
    // 签名材料进仓库等于把"谁都能签的钥匙"公开出去
    final ignore = File('.gitignore').readAsStringSync();
    expect(ignore, contains('key.properties'));
    expect(ignore, contains('*.jks'), reason: 'keystore 本体也要忽略');
    expect(ignore, contains('*.keystore'));
  });
}
