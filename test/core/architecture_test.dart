import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 架构边界测试（ADR-019 / ADR-024 / ADR-064）。
///
/// 用**源码扫描**代替额外 lint 依赖，零成本守住三条边界：
///   1. `lib/core` 不得依赖 Flutter（保证核心逻辑可纯 Dart 测试）；
///   2. `lib/core` / `lib/features` / `lib/sync` 不得出现 CloudBase SDK 类型；
///   3. 同上三层不得出现平台判断（`Platform.isX`）；
///   4. 依赖方向：core 不依赖 sync / features / ui；sync 不依赖 features / ui。
void main() {
  final files = _dartFiles(Directory('lib'));

  test('扫描到了源码文件（防止路径写错导致测试空转）', () {
    expect(files.length, greaterThan(10));
    expect(files.any((f) => f.path.contains('core')), isTrue);
  });

  test('分层识别正确（防止规则空转 —— 这里曾经出过 bug）', () {
    expect(_layerOf(File('lib/core/models/entity.dart')), 'core');
    expect(_layerOf(File('lib/sync/sync_engine.dart')), 'sync');
    expect(_layerOf(File('lib/features/workspace.dart')), 'features');
    expect(_layerOf(File('lib/ui/desktop/desktop_shell.dart')), 'ui');
    expect(_layerOf(File('lib/platform/data_directory.dart')), 'platform');
    expect(_layerOf(File('lib/main.dart')), 'root');

    // 每条分层规则都必须真的扫到了文件
    expect(_inLayer(files, 'core'), isNotEmpty);
    expect(_inLayer(files, 'sync'), isNotEmpty);
    expect(_inLayer(files, 'features'), isNotEmpty);
    expect(_inLayer(files, 'ui'), isNotEmpty);
    expect(_inLayer(files, 'platform'), isNotEmpty);
  });

  test('lib/core 不得 import Flutter', () {
    final offenders = <String>[];
    for (final file in _inLayer(files, 'core')) {
      for (final line in _imports(file)) {
        if (line.contains('package:flutter/')) {
          offenders.add('${_rel(file)} → $line');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'core 必须保持纯 Dart：\n${offenders.join('\n')}');
  });

  test('core / features / sync 不得出现 CloudBase SDK', () {
    final offenders = <String>[];
    for (final file in files.where((f) => _layerOf(f) != 'platform' && _layerOf(f) != 'ui')) {
      for (final line in _imports(file)) {
        if (line.contains('cloudbase')) offenders.add('${_rel(file)} → $line');
      }
    }
    expect(offenders, isEmpty, reason: '云端 SDK 只能出现在 lib/sync/cloudbase/ 下：\n${offenders.join('\n')}');
  });

  test('core / features / sync 不得出现平台判断', () {
    final offenders = <String>[];
    final pattern = RegExp(r'Platform\.is[A-Z]\w*');
    for (final file in files.where((f) => _layerOf(f) != 'platform' && _layerOf(f) != 'ui')) {
      final text = file.readAsStringSync();
      if (pattern.hasMatch(text)) {
        offenders.add(_rel(file));
      }
    }
    expect(offenders, isEmpty, reason: '平台差异只允许出现在 ui 与 platform 层：\n${offenders.join('\n')}');
  });

  test('依赖方向：core 不依赖 sync / features / ui', () {
    final offenders = <String>[];
    for (final file in _inLayer(files, 'core')) {
      for (final line in _imports(file)) {
        if (line.contains('/sync/') || line.contains('/features/') || line.contains('/ui/')) {
          offenders.add('${_rel(file)} → $line');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'core 是最底层，不能反向依赖：\n${offenders.join('\n')}');
  });

  test('依赖方向：sync 不依赖 ui', () {
    final offenders = <String>[];
    for (final file in _inLayer(files, 'sync')) {
      for (final line in _imports(file)) {
        if (line.contains('/ui/')) offenders.add('${_rel(file)} → $line');
      }
    }
    expect(offenders, isEmpty, reason: '同步层不应知道界面存在：\n${offenders.join('\n')}');
  });
}

List<File> _dartFiles(Directory dir) {
  if (!dir.existsSync()) return <File>[];
  final out = <File>[];
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) out.add(entity);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

Iterable<File> _inLayer(List<File> files, String layer) =>
    files.where((f) => _layerOf(f) == layer);

String _layerOf(File file) {
  final normalized = file.path.replaceAll(r'\', '/');
  for (final layer in <String>['core', 'sync', 'features', 'ui', 'platform']) {
    // 同时兼容 `lib/core/...` 与 `/lib/core/...` 两种写法 ——
    // 早先只判断带前导斜杠的形式，导致所有分层规则**空转**（永远通过）
    if (normalized.startsWith('lib/$layer/') || normalized.contains('/lib/$layer/')) {
      return layer;
    }
  }
  return 'root';
}

String _rel(File file) => file.path.replaceAll(r'\', '/');

List<String> _imports(File file) => file
    .readAsLinesSync()
    .where((line) => line.trimLeft().startsWith('import '))
    .toList(growable: false);
