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
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 只拦"某一步改名"：`deny` 返回 true 表示这一步被拒绝
  /// （模拟 EACCES / EPERM / EBUSY / 配额满）。
  ///
  /// 用注入点而不是 `attrib +R`：`attrib` 是 Windows 专用命令，Ubuntu CI 上
  /// `Process.runSync` 直接抛 `ProcessException` —— **CI 从 2026-09-27 建立起
  /// 就一直红在这两条用例上**；而 `chmod` 目录只读只会在创建 `.tmp` 时就抛，
  /// 走不到要守的兜底。注入点让两端走同一条确定性路径。
  void denyRenames(bool Function(File from, File to) deny) {
    AtomicFile.renameHook = (from, to) {
      if (deny(from, to)) throw FileSystemException('注入的失败：这一步改名被拒绝');
      from.renameSync(to.path);
    };
    addTearDown(() => AtomicFile.renameHook = null);
  }

  group('写入失败时原有数据必须还在（P1-1）', () {
    test('覆盖式 rename 被拒、兜底能走通：新数据就位，也不报错', () {
      final target = File('${dir.path}${Platform.pathSeparator}guideline.json')
        ..writeAsStringSync('真数据');

      // 只拦第一次（`_replace` 那一步）；兜底里的两次改名放行
      var attempt = 0;
      AtomicFile.renameHook = (from, to) {
        attempt += 1;
        if (attempt == 1) throw FileSystemException('注入的失败：不允许覆盖');
        from.renameSync(to.path);
      };
      addTearDown(() => AtomicFile.renameHook = null);

      expect(() => AtomicFile(target).writeText('新数据'), returnsNormally);
      expect(target.readAsStringSync(), '新数据', reason: '兜底走通了就该把新数据换上去');
      expect(
        File('${target.path}.old').existsSync(),
        isFalse,
        reason: '中转文件用完必须清掉，不能越积越多',
      );
    });

    test('兜底也换不上去：原文件必须原样回来，且如实报错', () {
      final target = File('${dir.path}${Platform.pathSeparator}guideline.json')
        ..writeAsStringSync('真数据');

      // 只要"目标是主文件"就拒绝：`_replace` 与兜底里的 `tmp → 目标` 都被拦，
      // 于是"新文件没就位 → 把原文件改回来"这条分支必然走到。
      final tmp = '${target.path}.tmp';
      denyRenames((from, to) => to.path == target.path && from.path == tmp);

      var threw = false;
      try {
        AtomicFile(target).writeText('新数据');
      } catch (_) {
        threw = true;
      }

      expect(threw, isTrue, reason: '没写进去就必须如实报错，绝不能静默成功');
      expect(
        target.existsSync(),
        isTrue,
        reason: '写入失败绝不能把唯一的主文件删掉 —— 这是不可逆的数据丢失',
      );
      expect(target.readAsStringSync(), '真数据', reason: '失败后留下的必须是原来的内容');
      expect(
        File('${target.path}.old').existsSync(),
        isFalse,
        reason: '原文件已经改回目标位，中转文件不该留下',
      );
      expect(File(tmp).existsSync(), isTrue, reason: '临时文件留着，启动时由 cleanupTmp 清掉');
    });

    test('连回改都失败：数据必须还躺在 .old 里，绝不许两份同时消失', () {
      final target = File('${dir.path}${Platform.pathSeparator}guideline.json')
        ..writeAsStringSync('真数据');

      // 所有"改名为主文件"的步骤都拒绝 → 中转成功、新文件没就位、回改也失败
      denyRenames((from, to) => to.path == target.path);

      var threw = false;
      try {
        AtomicFile(target).writeText('新数据');
      } catch (_) {
        threw = true;
      }

      expect(threw, isTrue, reason: '没写进去就必须如实报错');
      expect(
        File('${target.path}.old').readAsStringSync(),
        '真数据',
        reason: '目标位空了，但数据还在 .old —— 留一份给人工处理，总比两份都没了强',
      );
      expect(File('${target.path}.tmp').existsSync(), isTrue);
    });
  });

  test('同一毫秒隔离两次：第二份不会盖掉第一份的现场（P1-7）', () {
    final first = File('${dir.path}${Platform.pathSeparator}a.json')..writeAsStringSync('现场一');
    final firstPath = AtomicFile(first).quarantine(1000);
    expect(firstPath, isNotNull, reason: '隔离成功必须给出真实现场的路径');
    expect(first.existsSync(), isFalse, reason: '隔离就是把它改名挪走');

    // 同一个时间戳再来一次（同一测试里就会发生；真机上是时钟被回拨）
    final second = File('${dir.path}${Platform.pathSeparator}a.json')..writeAsStringSync('现场二');
    final secondPath = AtomicFile(second).quarantine(1000);

    expect(secondPath, isNot(firstPath), reason: '两份现场必须都在，不能互相覆盖');
    expect(File(firstPath!).readAsStringSync(), '现场一');
    expect(File(secondPath!).readAsStringSync(), '现场二');
  });

  test('隔离失败时返回 null，**不许把被隔离的文件自己当成现场**（2026-10-01 修）', () {
    // 旧写法失败时 `return file.path`，而 `AppStorage.load` 把返回值无条件记进
    // `quarantinedPaths` —— 于是界面上"已隔离保留现场"那句告警**指向主文件本身**，
    // 而紧接着 `_writeBackRecovered` 写的正是同一路径：告警指着的文件下一刻就被覆盖。
    //
    // 造"改名失败"：把**隔离目标本身**占成一个**目录** —— `renameSync` 往一个
    // 已存在的目录上覆盖会失败。
    // （第一次我试的是"把父目录做成文件"，不成立：Dart 的 `renameSync` 会自动建父目录，
    //   于是文件照样被改名走，用例红在"原文件保持不动"那条上。）
    final src = File('${dir.path}${Platform.pathSeparator}broken.json')
      ..writeAsStringSync('读不出来的内容');
    final target = AtomicFile.corruptOf(src, 1000);
    Directory(target.path).createSync(recursive: true);

    final result = AtomicFile(src).quarantine(1000);

    expect(result, isNull, reason: '隔离失败就说失败，不能返回一个不是现场的路径');
    expect(
      result,
      isNot(src.path),
      reason: '**尤其是不能返回被隔离文件自己的路径** —— 那会让告警指向它，'
          '而下一步恢复写回的就是它',
    );
    expect(src.existsSync(), isTrue, reason: '隔离失败时原文件保持不动');
    expect(src.readAsStringSync(), '读不出来的内容', reason: '内容也不许被改动');
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
