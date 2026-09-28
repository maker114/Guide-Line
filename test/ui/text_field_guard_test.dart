import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 扫源码：**每个用到裸 `TextField` 的界面文件，都要接上 `KeyboardDismissGuard`**。
///
/// 为什么要有这条（2026-09-29）：键盘那条缺陷在界面里是**一处处复制**的 ——
/// 灵感页修好了，搜索页、改名框、正文编辑页、设置页各自还有一份同样的毛病，
/// 全靠人去数。数漏一处，症状就只在那一个界面上出现，而"碰哪儿键盘都回来"
/// 这句话又很难被当成 bug 报上来。
///
/// 判据故意做得**粗但不会误伤**：同一个文件里既有裸 `TextField(`、又有
/// `KeyboardDismissGuard(` 就算过（`InlineTextField` 自带护栏，不算裸的）。
/// 它证明不了"包的是对的那个框"
/// （那个由 `keyboard_dismiss_test.dart` / `keyboard_dismiss_pages_test.dart` 守），
/// 但它能保证**新加输入框时不会忘了护栏**。
///
/// 语义分档见 ADR-086 / ADR-087：就地确认式收键盘 = 提交，
/// 页面级 / 常驻的收键盘 = 只放焦点。
void main() {
  /// 裸 `TextField(` —— **不算** `InlineTextField(`（那个自己已经带护栏了）。
  final bareField = RegExp(r'(?<!Inline)TextField\(');

  test('lib/ui 下每个用到 TextField 的文件都接了键盘护栏', () {
    final offenders = <String>[];

    for (final entity in Directory('lib/ui').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (!bareField.hasMatch(source)) continue;
      if (source.contains('KeyboardDismissGuard(')) continue;
      offenders.add(entity.path);
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些文件里有 TextField 却没有 KeyboardDismissGuard —— '
          '系统返回键收起键盘后焦点还留在框上，之后任何一次重建都会把键盘又唤出来。'
          '按 ADR-086 / ADR-087 接上护栏：就地确认式的按提交处理，'
          '页面级 / 常驻的只放掉焦点。\n  ${offenders.join('\n  ')}',
    );
  });
}
