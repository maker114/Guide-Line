import 'dart:io';

// 测试助手：把目录设成"写不进去"，用完再恢复 —— **跨平台**的那一份实现。
//
// 为什么要有这个文件：以前用例直接写 `Process.runSync('attrib', ['+R', dir])`，
// 而 `attrib` 是 Windows 专用命令 —— Ubuntu runner 上 `Process.runSync` 抛
// `ProcessException`，**CI 从 2026-09-27 建立起就一直红在这两条用例上**，
// 本机（Windows）却一直是绿的。以后要"制造写盘失败"，请用这里的东西。
//
// 两个平台的办法：
//   - Windows：`attrib +R <目录>`（只读属性对目录不是强约束，未必真拦得住）
//   - POSIX：`chmod 0500 <目录>`（GitHub runner 是普通用户，拦得住新建文件；
//     以 root 跑就拦不住）
// 两边都**不保证一定拦得住**，所以调用方要按实际结果断言（看备份有没有真落盘）。

/// 上锁要跑什么命令（纯函数：两个平台的分支都能在任一平台上被单测）。
({String command, List<String> arguments}) lockDirCommand(
  bool isWindows,
  String path,
) =>
    isWindows
        ? (command: 'attrib', arguments: <String>['+R', path])
        : (command: 'chmod', arguments: <String>['0500', path]);

/// 解锁要跑什么命令（纯函数，同上）。
({String command, List<String> arguments}) unlockDirCommand(
  bool isWindows,
  String path,
) =>
    isWindows
        ? (command: 'attrib', arguments: <String>['-R', path])
        : (command: 'chmod', arguments: <String>['0700', path]);

/// 把目录设成不可写；成功返回 `true`。
///
/// 这个环境做不到时（命令不存在、退出码非零）返回 `false`，**不抛异常** ——
/// "设不了"不是被测代码的错，调用方据此 `markTestSkipped`。
bool makeDirReadOnly(String path, {bool? isWindows}) =>
    _run(lockDirCommand(isWindows ?? Platform.isWindows, path));

/// 把目录恢复成可写；只用于收尾，失败也返回 `false`。
bool restoreDirWritable(String path, {bool? isWindows}) =>
    _run(unlockDirCommand(isWindows ?? Platform.isWindows, path));

bool _run(({String command, List<String> arguments}) plan) {
  try {
    return Process.runSync(plan.command, plan.arguments).exitCode == 0;
  } on ProcessException {
    // 这个平台上没有这个命令（正是当初 CI 变红的原因）
    return false;
  } on IOException {
    return false;
  }
}
