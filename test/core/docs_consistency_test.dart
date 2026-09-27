import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/platform/data_directory.dart';

/// **文档里的版本号必须跟着 `pubspec.yaml` 走**。
///
/// 这不是小题大做：2026-09-27 实测发现 README 顶上还写着「当前版本 1.3.0」，
/// 而应用已经发到 1.5.0 —— 它在 GitHub 首页最显眼的位置，说的却是三个版本前的事。
/// 起因是 Q38 那次只改了一版（1.1.0 → 1.3.0），之后每次升版本都没人想起它。
///
/// 所以这里把它钉住，与 `version_test.dart`（AppInfo ↔ pubspec）分工：
///   · `version_test.dart`：**打包用的**与**界面显示的**必须一致；
///   · 本文件：**对外文档（README）**里写的版本必须与 pubspec 一致，且
///     CHANGELOG 里真有这一版。
void main() {
  // 在 `main` 里算好、但**不要在测试外调 `expect`**（`expect` 只能在测试体内用，
  // 在外面会抛 `OutsideTestException`，整个文件连加载都过不去）
  final pubspecVersion = _readPubspecVersion();

  test('README 顶上的「当前版本」与 pubspec.yaml 一致', () {
    final readme = File('README.md');
    expect(readme.existsSync(), isTrue, reason: 'README.md 路径变了？');
    final text = readme.readAsStringSync();

    // 只认**加粗**的那一处：README 别处（历史记录、示例命令）可能提到别的版本
    final declared = RegExp(r'当前版本 \*\*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\*\*')
        .firstMatch(text)
        ?.group(1);
    expect(declared, isNotNull, reason: 'README 里找不到形如「当前版本 **1.5.0+23**」的那一行');
    expect(
      declared,
      pubspecVersion,
      reason: 'README 的「当前版本」是给外面看的门面，滞后一个版本就会被当成事实',
    );
  });

  test('CHANGELOG 里有 pubspec.yaml 声明的那一版', () {
    final changelog = File('CHANGELOG.md');
    expect(changelog.existsSync(), isTrue, reason: 'CHANGELOG.md 路径变了？');
    final version = pubspecVersion.split('+').first;
    expect(
      changelog.readAsStringSync(),
      contains('## [$version]'),
      reason: '升了版本却没在 CHANGELOG 里开一节；或者反过来，CHANGELOG 记了这一版而 pubspec 没升',
    );
  });

  test('pubspec.yaml 那一版与 AppInfo 一致', () {
    expect(
      '${AppInfo.version}+${AppInfo.buildNumber}',
      pubspecVersion,
      reason: 'AppInfo ↔ pubspec 由 version_test.dart 守着，这里顺手再确认一次',
    );
  });
}

/// 读 `pubspec.yaml` 里唯一的 `version:` 行；读不到就抛一条**能读懂**的错误。
String _readPubspecVersion() {
  final lines = File('pubspec.yaml')
      .readAsLinesSync()
      .where((l) => l.startsWith('version:'))
      .toList(growable: false);
  if (lines.isEmpty) {
    throw StateError('pubspec.yaml 里找不到 version: 行');
  }
  return lines.first.substring('version:'.length).trim();
}
