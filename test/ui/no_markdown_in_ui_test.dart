import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 界面文案里**不许出现 Markdown 记号**。
///
/// 这个测试来自一个真实缺陷：归档区的说明文案写成了
/// `只列**归档根**（…）`，而它被塞进的是普通 `Text`，
/// 于是屏幕上真的显示出四个星号。注释里用 Markdown 是对的，
/// 但**运行时字符串**不会经过任何 Markdown 渲染，写什么就显示什么。
///
/// 用源码扫描代替人工检查（零依赖，和架构边界测试同一套路数）。
void main() {
  final files = _dartFiles(Directory('lib'));

  test('扫描到了源码文件（防止路径写错导致测试空转）', () {
    expect(files.length, greaterThan(10));
  });

  test('运行时字符串里不得出现 Markdown 强调记号', () {
    final offenders = <String>[];
    for (final file in files) {
      for (final line in file.readAsLinesSync()) {
        final code = _stripComment(line);
        // 只查 `**`：`__` 在代码里是合法写法（例如哨兵常量 `'__none__'`），
        // 而中文文案里几乎只会误用 `**加粗**` 这一种。
        if (code.contains('**')) {
          offenders.add('${_rel(file)}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些字符串会被原样显示给用户，请去掉 Markdown 记号'
          '（要强调就用「」或汉字本身）：\n${offenders.join('\n')}',
    );
  });
}

/// 去掉行内的注释部分：`/// 文档注释里有 **加粗**` 是合法的，不该被拦。
/// `https://` 里的双斜杠不是注释起始，要跳过。
String _stripComment(String line) {
  var from = 0;
  while (true) {
    final at = line.indexOf('//', from);
    if (at < 0) return line;
    if (at > 0 && line[at - 1] == ':') {
      from = at + 2;
      continue;
    }
    return line.substring(0, at);
  }
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

String _rel(File file) => file.path.replaceAll(r'\', '/');
