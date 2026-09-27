import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/store/atomic_file.dart';

/// `AtomicFile` 的原子替换底线：**写入失败时原有数据必须还在**。
///
/// 这是单文件存储「全有或全无」的根基，所以单独守一份。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_atomic_');
  });

  tearDown(() {
    // 用例里可能把文件设成只读，先恢复再删
    if (dir.existsSync()) {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          try {
            entity.setLastModifiedSync(DateTime.now());
            Process.runSync('attrib', <String>['-R', entity.path]);
          } catch (_) {
            // 恢复不了也不影响用例结果
          }
        }
      }
      dir.deleteSync(recursive: true);
    }
  });

  test('写入失败时原有数据必须还在（P1-1）', () {
    final target = File('${dir.path}${Platform.pathSeparator}guideline.json');
    target.writeAsStringSync('真数据');

    // 目标文件只读 → 覆盖式 rename 会失败。
    // 旧实现在这个 catch 里**无条件**删掉目标再改名，于是主文件消失、新文件也没就位。
    Process.runSync('attrib', <String>['+R', target.path]);

    var threw = false;
    try {
      AtomicFile(target).writeText('新数据');
    } catch (_) {
      threw = true;
    }

    if (!threw) {
      // 平台允许覆盖式 rename（那就没走到兜底），此时新数据应当已就位
      expect(target.readAsStringSync(), '新数据');
      return;
    }

    expect(
      target.existsSync(),
      isTrue,
      reason: '写入失败绝不能把唯一的主文件删掉 —— 这是不可逆的数据丢失',
    );
    expect(
      target.readAsStringSync(),
      '真数据',
      reason: '失败后留下的必须是原来的内容，不能是半截或空文件',
    );
  });

  test('同一毫秒隔离两次：第二份不会盖掉第一份的现场（P1-7）', () {
    final first = File('${dir.path}${Platform.pathSeparator}a.json')..writeAsStringSync('现场一');
    final firstPath = AtomicFile(first).quarantine(1000);
    expect(first.existsSync(), isFalse, reason: '隔离就是把它改名挪走');

    // 同一个时间戳再来一次（同一测试里就会发生；真机上是时钟被回拨）
    final second = File('${dir.path}${Platform.pathSeparator}a.json')..writeAsStringSync('现场二');
    final secondPath = AtomicFile(second).quarantine(1000);

    expect(secondPath, isNot(firstPath), reason: '两份现场必须都在，不能互相覆盖');
    expect(File(firstPath).readAsStringSync(), '现场一');
    expect(File(secondPath).readAsStringSync(), '现场二');
  });

  test('cleanupTmp：清掉上次崩溃留下的 .tmp，主文件原样不动（T-8）', () {
    // 这条路径由 `AppStorage.load` 在每次启动时调用，却一直没有用例 ——
    // 它守的是"半截写入留下的临时文件不会越积越多、也不会被误当数据读"。
    final store = File('${dir.path}${Platform.pathSeparator}guideline.json')
      ..writeAsStringSync('真数据');
    final leftover = AtomicFile.tmpOf(store)..writeAsStringSync('半截写入的内容');

    AtomicFile.cleanupTmp(<File>[store]);

    expect(leftover.existsSync(), isFalse, reason: '遗留的 .tmp 要被清掉');
    expect(store.readAsStringSync(), '真数据', reason: '主文件绝不能被碰');
  });

  test('cleanupTmp：没有 .tmp 时什么都不做（不抛错）', () {
    final store = File('${dir.path}${Platform.pathSeparator}guideline.json')
      ..writeAsStringSync('真数据');
    expect(() => AtomicFile.cleanupTmp(<File>[store]), returnsNormally);
    expect(store.readAsStringSync(), '真数据');
  });

  test('fsyncHook：每次原子写入都会为临时文件与目标各调一次（P1-4）', () {
    // `flushSync` 不等于 fsync，真正的落盘由平台层注入的钩子完成。
    // 这里验证**注入点确实被走到**：Dart 侧没有别的办法证明"原生的 fsync 被调用了"。
    final target = File('${dir.path}${Platform.pathSeparator}guideline.json');
    final flushed = <String>[];
    AtomicFile.fsyncHook = flushed.add;
    addTearDown(() => AtomicFile.fsyncHook = null);

    AtomicFile(target).writeText('数据');

    expect(target.readAsStringSync(), '数据', reason: '加固不能影响正常写入');
    expect(flushed, hasLength(2), reason: '临时文件刷一次 + rename 之后的目标再刷一次');
    expect(flushed.first, endsWith('.tmp'));
    expect(flushed.last, target.path);
  });

  test('fsyncHook：钩子抛异常也不影响保存成功（降级不阻断）', () {
    final target = File('${dir.path}${Platform.pathSeparator}guideline.json');
    AtomicFile.fsyncHook = (_) => throw StateError('模拟原生侧失败');
    addTearDown(() => AtomicFile.fsyncHook = null);

    expect(() => AtomicFile(target).writeText('数据'), returnsNormally);
    expect(target.readAsStringSync(), '数据');
  });

  test('fsyncHook：没接钩子时（桌面/测试）一切照旧', () {
    final target = File('${dir.path}${Platform.pathSeparator}guideline.json');
    AtomicFile.fsyncHook = null;
    expect(() => AtomicFile(target).writeText('数据'), returnsNormally);
    expect(target.readAsStringSync(), '数据');
  });
}
