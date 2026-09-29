import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'readonly_dir.dart';

/// 守这个助手本身：
///   1. 命令计划在两个平台上都对（Windows 上根本没有 `chmod`，Linux 上没有 `attrib`）——
///      纯函数，所以两个分支在任一平台上都能验；
///   2. 真上锁 → 真恢复这条链路在本机可用，收尾能删干净。
void main() {
  test('Windows 计划：attrib +R / -R（这一条正是当初 CI 缺的东西）', () {
    const path = r'C:\tmp\d';
    final lock = lockDirCommand(true, path);
    expect(lock.command, 'attrib');
    expect(lock.arguments, <String>['+R', path]);

    final unlock = unlockDirCommand(true, path);
    expect(unlock.command, 'attrib');
    expect(unlock.arguments, <String>['-R', path]);
  });

  test('POSIX 计划：chmod 0500 / 0700（Ubuntu runner 上真跑的就是这一条）', () {
    const path = '/tmp/d';
    final lock = lockDirCommand(false, path);
    expect(lock.command, 'chmod');
    expect(lock.arguments, <String>['0500', path]);

    final unlock = unlockDirCommand(false, path);
    expect(unlock.command, 'chmod');
    expect(unlock.arguments, <String>['0700', path]);
  });

  test('真上锁再恢复：命令能跑（设不拦得住看平台），恢复之后一定还能写能删', () {
    final dir = Directory.systemTemp.createTempSync('guideline_ro_');
    addTearDown(() {
      restoreDirWritable(dir.path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final locked = makeDirReadOnly(dir.path);

    // 不判"拦住了没有"：Windows 的 `attrib +R` 对目录不是强约束，Linux 上 chmod 拦得住，
    // 而**"设不上"必须是返回 false 而不是抛异常** —— 这就是 CI 变红的那个坑。
    expect(
      restoreDirWritable(dir.path),
      isTrue,
      reason: '本机必须能恢复权限，否则用例收尾会删不掉临时目录',
    );

    final probe = File('${dir.path}${Platform.pathSeparator}probe.json');
    expect(
      () => probe.writeAsStringSync('数据'),
      returnsNormally,
      reason: '恢复之后必须能写（locked=$locked）',
    );
    expect(
      () => dir.deleteSync(recursive: true),
      returnsNormally,
      reason: '恢复之后必须能删干净',
    );
  });
}
