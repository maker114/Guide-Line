import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/platform/data_directory.dart';

/// 代码里引用 ADR 编号的写法：`ADR-053`、`ADR-002`。
///
/// **故意不匹配 `ADR-0xx` 这种占位写法**（文档里用它表示"某个 ADR"，没有具体编号），
/// 也不匹配更长数字（`ADR-0531`）。
final RegExp _adrPattern = RegExp(r'ADR-\d{2,3}(?!\d)');

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

  // ---------------------------------------------------------------------------
  // 下面两道闸守的是**引用本身**，不是版本号。
  //
  // 起因：2026-09-27 发现代码里有 31 个 Q 编号、16 个 ADR 编号在流通，而其中
  // `Q53` / `Q42` / `Q37` / `Q38` 当年有两个互不相干的定义（旧设计文档一套、新版修改
  // 计划一套），`ADR-037` 甚至是被打错的 `ADR-033/037`。定义它们的文档早已随电脑端
  // 工程归档 —— 也就是"_引用了谁也不知道定义的编号_"。
  // 治本办法不是禁止编号（那要改 223 处），而是让每个编号都有一个**活着的落点**：
  // `docs/决策索引.md`。下面第一条保证"索引里有"，第二条保证"spec 里不写进度"。
  // ---------------------------------------------------------------------------

  test('代码里引用的每个 ADR 编号，都在《决策索引》里有落点', () {
    final index = File('docs/决策索引.md');
    expect(
      index.existsSync(),
      isTrue,
      reason: '《决策索引》被移走了？代码里的 ADR 编号就全成了暗号',
    );
    final indexText = index.readAsStringSync();

    final referenced = <String, List<String>>{}; // 编号 → 引用它的位置
    for (final dir in <String>['lib', 'test']) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final m in _adrPattern.allMatches(entity.readAsStringSync())) {
          final id = m.group(0)!;
          (referenced[id] ??= <String>[]).add(entity.path);
        }
      }
    }

    expect(referenced, isNotEmpty, reason: '一个 ADR 编号都没扫到？扫描路径写错了');

    final orphans = referenced.entries
        .where((e) => !indexText.contains('${e.key} |'))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    expect(
      orphans,
      isEmpty,
      reason: '这些编号被代码引用，但《决策索引》§3 里没有它们的行 —— '
          '谁都不知道它当初裁定了什么。要么补进索引，要么把引用改成自足的说明：\n'
          '${orphans.map((e) => '  ${e.key} ← ${e.value.join(', ')}').join('\n')}',
    );
  });

  test('spec 文档里不许写"做到哪一步了"', () {
    // 口径归 spec，进度归《决策索引》与 CHANGELOG。混在一起的结果是：
    // 2026-09-27 发现《定义与边界》当时的 §8/§10 里 12 条陈述与代码事实相反
    // （写着"还没落地"的其实早落地了），而它自己声明是"口径权威"。
    final banned = <String>['还没落地', '未实施', '待实施', '待做', '尚未实施', '还没做'];
    final offenders = <String>[];

    final spec = Directory('docs/spec');
    expect(spec.existsSync(), isTrue, reason: 'docs/spec 路径变了？');
    for (final entity in spec.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final text = entity.readAsStringSync();
      for (final word in banned) {
        if (text.contains(word)) offenders.add('${entity.path} 出现了「$word」');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'spec 是口径，不是进度表。把这几句换成"见 docs/决策索引.md"，'
          '或者把进度写进 CHANGELOG：\n  ${offenders.join('\n  ')}',
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
