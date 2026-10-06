import 'dart:convert';
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

  test('三处「例数」必须说同一个数，而且不许把测试规模说小', () {
    // ## 这道闸为什么是现在这个样子（它换过两次形状）
    //
    // 第一版钉的是"README 写的数 == `test/` 下声明的条数"。**那个口径是错的**，
    // 而且错得很隐蔽：声明条数 ≠ `flutter test` 跑出来的数，因为有用例是在
    // `for` 循环里生成的（`json_contract_test.dart` 按集合名、
    // `source_chip_tone_test.dart` 按主题×明暗、`theme_test.dart`、`contract_evolution_test.dart`
    // 都这么写）。2026-10-01 实测：**声明 832 条，跑出来 +850**。
    // 第一版把 832 写进 README，用户照着敲 `flutter test` 看到的却是 `+850`。
    //
    // 第二版改成"只钉一条诚实的下限"，于是 README 那个数不会偏小 ——
    // **但它拦不住偏高，也管不着别的文档**。2026-10-01 独立核验实测到三处
    // 说的是三个数：README「约 880」、`docs/开发节奏.md`「约 850」、
    // `docs/构建与发布.md`「810 例全绿」，而当时真值是 876。
    // 「开发节奏」那一处还自称"照 README 的口径" —— 可见只守一处等于没守。
    //
    // 现在第三版：**三处一起管，且三处必须说同一个数**。
    // 两条判据各管一件事：
    //   · 每条都不许小于静态声明数（别把规模说小）；
    //   · 三处彼此相等（别各自漂）。
    // 仍然**不钉精确值**（那是第一版的错）：允许带「约」字，也允许不带。
    final sources = <String, String>{
      // 2026-10-06：README 重写成"软件介绍"之后，例数这类技术数字搬到了
      // `docs/工程说明.md` —— 这一闸跟着搬，三处仍然必须说同一个数。
      'docs/工程说明.md': '工程说明',
      'docs/开发节奏.md': '开发节奏',
      'docs/构建与发布.md': '构建与发布',
    };
    final floor = _countTestDeclarations();
    final found = <String, int>{};

    sources.forEach((path, label) {
      final text = File(path).readAsStringSync();
      // 只认「**约** N 例」这个写法（三处当前口径都是它）。
      //
      // 为什么必须带「约」、不能只认 `N 例`：这三篇文档里**本来就有别的** `N 例` ——
      // `开发节奏.md` 记着"那时全量才 177 例"（历史快照）、还讲"一次加 3 例"这类
      // 说明性数字。把它们一起抓进来，守卫会红在一个与被测口径毫无关系的地方
      // （第一版就是栽在这种误伤上）。带「约」字同时表达了两件事：
      // **这是估计值**、**这是当前口径**。
      final numbers = RegExp(r'约 (\d+) 例')
          .allMatches(text)
          .map((m) => int.parse(m.group(1)!))
          .toSet();
      expect(
        numbers,
        isNotEmpty,
        reason: '$path 里找不到形如「约 N 例」的那一处。'
            '这个数**必须写在文档里**（并带上「约」字），否则用户不知道测试规模、'
            '也没人守它。',
      );
      expect(
        numbers.length,
        1,
        reason: '$path 里出现了多个不同的例数：$numbers —— '
            '同一份文档前后说法不一致，读的人不知道该信哪个。',
      );
      final count = numbers.single;
      expect(
        count,
        greaterThanOrEqualTo(floor),
        reason: '$path 说"约 $count 例"，而仅静态声明就有 $floor 条 —— 把测试规模说小了。'
            '往大改，别往下改。',
      );
      found[label] = count;
    });

    expect(
      found.values.toSet().length,
      1,
      reason: '三处必须说**同一个数**，实际是：$found。'
          '这个数由 `test/core/docs_consistency_test.dart` 统一对着 —— '
          '改一处不改另两处，这条就会红（2026-10-01 它们一度分别是 880 / 850 / 810）。',
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

  test('《决策索引》里的「代码引用」列与实际次数一致（ADR 与 Q 都要）', () {
    // 为什么加这一条：上面那条只查"编号有没有行"，**不查行里的数对不对** ——
    // 2026-10-01 实测发现 ADR 有 **9 处**、Q 有 **10 处**记的数早就过期了
    // （ADR-095 记 0、实际 27；Q32 记 12、实际 4 ……）。
    // 那一列如果只是装饰就罢了，但它的用途写得很明确：
    // **"大于 0 的条目，改动受影响的代码时必须同步本行"** ——
    // 数不对，这条纪律就没有依据。
    //
    // 口径与索引 §3 开头那句一致：`ADR-\d{2,3}` / `\bQ\d{1,2}\b` 全文匹配，
    // 扫 `lib/` 与 `test/` 的 `.dart`，**不含本文件**
    // （这里出现的编号只是"编号长什么样"的示例，不是引用）。
    final indexLines = File('docs/决策索引.md').readAsLinesSync();
    final adrActual = _countReferences(RegExp(r'ADR-\d{2,3}'));
    final qActual = _countReferences(RegExp(r'\bQ\d{1,2}\b'));

    expect(adrActual, isNotEmpty, reason: '一个 ADR 编号都没扫到？扫描路径写错了');
    expect(qActual, isNotEmpty, reason: '一个 Q 编号都没扫到？扫描路径写错了');

    // 表里的一行形如 `| ADR-095 | 说明… | 27 | 落点… |` ——
    // 编号在第 2 格、引用数在第 4 格。`~ADR-0xx~` 是被划掉的那些，照样要对齐。
    final rowPattern = RegExp(r'^\|\s*~*((?:ADR-\d{2,3})|(?:Q\d{1,2}))~*\s*\|.*?\|\s*(\d+)\s*\|');
    final mismatches = <String>[];
    var checked = 0;
    for (final line in indexLines) {
      final m = rowPattern.firstMatch(line);
      if (m == null) continue;
      final id = m.group(1)!;
      final recorded = int.parse(m.group(2)!);
      final actual = id.startsWith('ADR') ? (adrActual[id] ?? 0) : (qActual[id] ?? 0);
      checked += 1;
      if (recorded != actual) {
        mismatches.add('  $id：索引记 $recorded，实际 $actual');
      }
    }

    expect(checked, greaterThan(50), reason: '只认出 $checked 行？表格形状变了');
    expect(
      mismatches,
      isEmpty,
      reason: '《决策索引》的「代码引用」列与代码里的实际次数对不上：\n'
          '${mismatches.join('\n')}\n'
          '改代码时顺手更新那一格；那一列的用途就是"哪些条目的代码值得盯" —— 数不准就没用。',
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

/// `lib/` 与 `test/` 的 `.dart` 里某个编号模式出现的**总次数**（编号 → 次数）。
///
/// **不含本文件**：这里是"编号长什么样"的示例所在的文件，算进来会自我指涉 ——
/// 上面的 `_adrPattern` 与 `rowPattern` 里各有一处字面量，会让 ADR 的计数凭空多出来。
Map<String, int> _countReferences(RegExp pattern) {
  final counts = <String, int>{};
  for (final dir in <String>['lib', 'test']) {
    final root = Directory(dir);
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.uri.pathSegments.last == 'docs_consistency_test.dart') continue;
      for (final m in pattern.allMatches(entity.readAsStringSync())) {
        final id = m.group(0)!;
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
  }
  return counts;
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

/// `test/` 下**静态声明**的用例数：数行首（允许缩进）的 `test(` 与 `testWidgets(`。
///
/// **这是一个下限，不是 `flutter test` 跑出来的那个数。** 两者的差是真实的：
/// 有用例写在 `for` 循环里，一行声明会跑出好几条 ——
/// `json_contract_test.dart`（按集合名）、`source_chip_tone_test.dart`（主题×明暗）、
/// `theme_test.dart`、`contract_evolution_test.dart` 都这么写。
/// 2026-10-01 实测：本函数数到 **832**，`flutter test` 打印 **+850**。
///
/// 所以调用方（"例数不许伪装成精确值"那条）只拿它当前**下限**用：
/// 文档里说的数不许比它小。**别拿它去和 `+N` 比相等** —— 那正是这道闸
/// 第一版犯过的错。
///
/// 另一处已知的少计：声明与 `group(` 写在同一行时数不到
/// （`contract_evolution_test.dart` 里有一处）。对"下限"这个用途无影响，
/// 所以有意不修 —— 修了会把它伪装得更像精确值。
int _countTestDeclarations() {
  final pattern = RegExp(r'^\s*(?:test|testWidgets)\(');
  final root = Directory('test');
  expect(root.existsSync(), isTrue, reason: 'test/ 路径变了？');
  var count = 0;
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    // 用字节解码并允许坏字节：这个文件会在 Windows 上跑，代码页不该影响"数了几条"
    final text = utf8.decode(entity.readAsBytesSync(), allowMalformed: true);
    for (final line in const LineSplitter().convert(text)) {
      if (pattern.hasMatch(line)) count += 1;
    }
  }
  expect(count, greaterThan(100), reason: '只数到 $count 条？扫描路径或正则大概写错了');
  return count;
}
