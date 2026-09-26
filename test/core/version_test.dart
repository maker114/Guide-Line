import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/platform/data_directory.dart';

/// 界面上显示的版本号必须与**打包用的** `pubspec.yaml` 一致。
///
/// 这是一次真实事故的守护：版本号以前在 `pubspec.yaml`、关于对话框、更多页各写一遍，
/// 发版时必然漏一个（1.0.0 一直漏到 1.1.0 才发现是哪一处没改）。
/// 现在界面只读 [AppInfo] 这一个源头，但那个源头本身仍要和 `pubspec.yaml` 对上 ——
/// 对不上就会出现"装出来的包是 1.3.0+4、关于页写着 1.1.0+2"，而用户和客服看到的都是后者。
///
/// 这个测试扫源码（和架构边界测试、Android 清单测试同一套路数），不需要真机或打包。
void main() {
  test('AppInfo 的版本号与 pubspec.yaml 的 version 行一致', () {
    final pubspec = File('pubspec.yaml');
    expect(pubspec.existsSync(), isTrue, reason: 'pubspec.yaml 路径变了？');

    // 取第一行以 `version:` 开头的（注释里的行都以 `#` 开头，不会误命中）
    final lines = pubspec
        .readAsLinesSync()
        .where((l) => l.startsWith('version:'))
        .toList(growable: false);

    // `version: 1.3.0+4` → `1.3.0+4`
    final declared =
        lines.isEmpty ? '' : lines.first.substring('version:'.length).trim();
    expect(declared, isNotEmpty, reason: 'pubspec.yaml 里找不到 version: 行，或它没写版本号');

    expect(
      '${AppInfo.version}+${AppInfo.buildNumber}',
      declared,
      reason: 'AppInfo 与 pubspec.yaml 的版本号不一致：改版本时两处都要改'
          '（界面显示的是 AppInfo，安装包用的是 pubspec.yaml）',
    );
  });
}
