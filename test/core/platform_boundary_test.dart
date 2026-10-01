import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **插件只能出现在 `lib/platform`** —— `AGENTS.md` §9 的硬规则里，此前唯一一道
/// 没有任何机器守卫的。这份文件把它补上。
///
/// 为什么这条值得一道测试：它是全仓**唯一一条"加一行 import 就能破、而且不会红"**
/// 的架构规则。`architecture_test.dart` 守的是 `lib/core` 不许 import Flutter、
/// 层间依赖方向、不许出现云端 SDK —— 它**从不看第三方 package**
/// （见该文件 `_imports` 的用法：只拿路径做 `contains` 判断）。
/// 于是"在 `lib/ui` 里直接 import 一个插件"这件事，改完 `analyze` 是绿的、
/// 全部用例也是绿的，只有人翻代码才看得出来。
///
/// 破了会怎样：`lib/core` / `lib/features` 保持纯 Dart 的意义在于**它们能在宿主机
/// 上直接跑单测**；`lib/ui` 只依赖 Flutter 而不依赖具体平台插件，才有
/// "两套外壳共用同一份页面"这件事。插件一旦漏进这些层，宿主机的测试会开始
/// 依赖平台实现，桌面端与手机端的差异会从 `lib/platform` 一个地方散到全仓。
///
/// **判定口径**：
///   · `package:flutter/`（含 `flutter_test`）是 SDK，不是插件 —— 除 `lib/core`
///     由 `architecture_test.dart` 管着之外，别处**随便用**，本文件不管；
///   · `package:guideline/` 是工程自己的包（`pubspec.yaml` 的 `name:`），不是依赖；
///   · 其余一律算第三方依赖 —— 只能出现在 `lib/platform/` 下。
///
/// 与 `README.md` 里"运行时依赖只有五个"那句是**两件事**：那句说的是 `pubspec.yaml`
/// 的声明（含模板自带、本工程一处没用的 `cupertino_icons`），
/// 这里说的是**代码里真的 import 了谁**。
void main() {
  final files = _dartFiles(Directory('lib'));

  /// 插件被**允许**出现的地方：整个平台适配层。
  ///
  /// 不按单个插件登记路径，而是整层放行 —— 与 `AGENTS.md` 的口径一致
  /// （"新增插件只能出现在 `lib/platform`"），也免得每加一个插件都要来改这份测试。
  const String platformLayer = 'lib/platform/';

  /// 工程自己的包名，从 `pubspec.yaml` 的 `name:` 读，**不写字面量**：
  /// 写死的话，哪天包名改了，这道守卫会突然把本工程所有文件都判成"用了第三方插件"。
  final ownPackage = _readPubspecName();

  test('扫描到了源码文件（防止路径写错导致本文件空转）', () {
    // 与 architecture_test.dart 同一条教训：分层规则曾经因为路径写法不对而**全部空转**，
    // 永远通过。先确认真的扫到了东西。
    expect(files.length, greaterThan(50), reason: 'lib 下只扫到 ${files.length} 个 .dart，路径大概写错了');
    expect(
      files.where((f) => _normalize(f.path).startsWith(platformLayer)),
      isNotEmpty,
      reason: '一个 lib/platform 下的文件都没扫到？',
    );
  });

  test('第三方 package 只允许出现在 lib/platform 下（AGENTS.md §9）', () {
    final offenders = <String>[];

    for (final file in files) {
      final path = _normalize(file.path);
      if (path.startsWith(platformLayer)) continue; // 平台适配层：它就是干这个的
      for (final name in _packageImports(file)) {
        if (_sdkPackages.contains(name) || name == ownPackage) continue;
        offenders.add('$path → package:$name/');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些文件 import 了第三方依赖，但插件只能出现在 `lib/platform/`：\n'
          '${offenders.join('\n')}\n\n'
          '两种改法：把这段能力挪进 `lib/platform/`（并在那里给 core 留一个纯 Dart 接口），'
          '或者把这条依赖从 `pubspec.yaml` 摘掉。',
    );
  });

  test('插件的现有落点没变（哪几个包、各自几处，都要与这份清单对得上）', () {
    // 上一条只回答"有没有漏进来的"。这一条回答"**登记在册的是不是还是这些**"：
    // 插件被整批删掉、或换了个包名，上一条会照样绿（它只查违规，不查存在），
    // 而依赖面貌已经变了却没人知道。
    final actual = <String, int>{};
    for (final file in files) {
      final path = _normalize(file.path);
      if (!path.startsWith(platformLayer)) continue;
      for (final name in _packageImports(file)) {
        if (_sdkPackages.contains(name) || name == ownPackage) continue;
        actual[name] = (actual[name] ?? 0) + 1;
      }
    }

    expect(
      actual,
      _expectedPluginImports,
      reason: 'lib/platform 里实际 import 的第三方依赖与登记的清单不一致。\n'
          '新增了依赖 → 把它加进本文件的 `_expectedPluginImports` 并说明为什么需要它；\n'
          '删掉了依赖 → 从清单里划掉，顺带确认 `pubspec.yaml` 与 `README.md` 的依赖清单也跟着改了。',
    );
  });

  test('清单里的每个包都真的在 pubspec.yaml 里声明过', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final missing = _expectedPluginImports.keys
        .where((name) => !pubspec.contains('\n  $name:'))
        .toList(growable: false);

    expect(
      missing,
      isEmpty,
      reason: '这些包被 `lib/platform` import 了，却没在 `pubspec.yaml` 的 dependencies 里声明：'
          '$missing\n（transitive 依赖能用但不该直接用 —— analyze 的 '
          'depend_on_referenced_packages 会报，这道断言把它钉在测试里）',
    );
  });
}

/// 允许出现在任何一层的 SDK 包（不是插件）。
const Set<String> _sdkPackages = <String>{'flutter', 'flutter_test'};

/// `lib/platform` 下**当前**真的在用的插件，以及各自被 import 的处数。
///
/// 这不是白名单（白名单是"整层放行"），是**登记册**：它让"依赖面貌变了"这件事
/// 必须由一个提交显式说明，而不是悄悄发生。处数写死是有意的 ——
/// 同一插件多 import 一处也要来改这里，改动于是会出现在 diff 里。
const Map<String, int> _expectedPluginImports = <String, int>{
  // 密钥：AI 的 apiKey、GitHub 的 token —— 只在系统安全存储里
  'flutter_secure_storage': 2, // ai_client.dart、github_backup_client.dart
  'http': 2, // ai_client.dart、github_backup_client.dart
  'path_provider': 1, // data_directory.dart
  'file_picker': 1, // data_transfer_platform.dart
  'share_plus': 1, // data_transfer_platform.dart
};

List<File> _dartFiles(Directory dir) {
  if (!dir.existsSync()) return <File>[];
  final out = <File>[];
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) out.add(entity);
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

String _normalize(String path) => path.replaceAll(r'\', '/');

/// 一个文件里 `package:` 形式的 import 的**包名**（去重，保持出现顺序）。
///
/// 只认真正的 `import` 行，**不含 `//` 注释里被引用的例子** ——
/// 本仓库的注释极爱举 `package:` 的例子（例如 `architecture_test.dart` 里
/// 就写过 `package:flutter/`），把注释算进来会制造假报。
Iterable<String> _packageImports(File file) {
  final names = <String>[];
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trimLeft();
    if (line.startsWith('//')) continue;
    // 合并写法要给 `package:` 之前留出真正的空格，否则会把
    // `// import 'package:x/...'` 这类行尾注释也算进来
    if (!line.startsWith('import ')) continue;
    for (final m in _packagePattern.allMatches(line)) {
      final name = m.group(1)!;
      if (!names.contains(name)) names.add(name);
    }
  }
  return names;
}

/// `package:<包名>/`。包名允许 `_` 与数字（`flutter_secure_storage`、`share_plus`）。
final RegExp _packagePattern = RegExp(r'package:([A-Za-z_][A-Za-z0-9_]*)/');

/// 读 `pubspec.yaml` 的 `name:`（顶格那一行，不是 `description:` 里出现的字）。
String _readPubspecName() {
  final lines = File('pubspec.yaml')
      .readAsLinesSync()
      .where((l) => l.startsWith('name:'))
      .toList(growable: false);
  if (lines.isEmpty) {
    throw StateError('pubspec.yaml 里找不到 name: 行');
  }
  return lines.first.substring('name:'.length).trim();
}
