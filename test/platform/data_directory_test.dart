import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/platform/data_directory.dart';

/// 数据目录落点的护栏（电脑端第一件必须钉死的事）。
///
/// 背景：`DataDirectory.resolve()` 曾经是"Android/iOS 走应用私有目录，
/// **其它一律** `Directory.current/data`"。在手机上没事（正式平台就是 Android），
/// 但打包成 exe 之后 `Directory.current` 可能是任意位置 —— 用户双击运行，
/// 数据就堆在程序旁边的 `data\` 里，既不符合"应用私有目录"的安全模型，
/// 也会让同一台机器上多份拷贝各写各的。
void main() {
  test('显式传入的目录优先（测试与将来"选数据目录"功能都靠它）', () async {
    final explicit = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}guideline-explicit',
    );
    final dir = await DataDirectory.resolve(override: explicit);
    expect(dir.path, explicit.path);
  });

  test('解析结果绝不落在当前工作目录下', () async {
    final dir = await DataDirectory.resolve();
    final cwd = Directory.current.absolute.path;
    final resolved = dir.absolute.path;

    // 仓库 / 工作目录本身，以及它下面的任何位置都算踩线
    expect(
      resolved == cwd || _isUnder(resolved, cwd),
      isFalse,
      reason: '数据目录落到了工作目录里（$resolved）—— 打包后就会写到程序旁边，'
          '这正是不许再出现的旧行为',
    );
  });

  test('Windows 上落在 %LOCALAPPDATA%，拿不到才退临时目录', () async {
    // 这条只在 Windows 宿主上有意义；CI 的 Linux runner 上跳过。
    if (!Platform.isWindows) {
      markTestSkipped('仅在 Windows 上校验桌面落点');
      return;
    }

    final dir = await DataDirectory.resolve();
    final path = dir.absolute.path;
    final localAppData = Platform.environment['LOCALAPPDATA'];

    if (localAppData != null && localAppData.isNotEmpty) {
      expect(
        _isUnder(path, localAppData),
        isTrue,
        reason: '应落在 %LOCALAPPDATA% 下（本机私有、不参与账户漫游），实际是 $path',
      );
      expect(path, endsWith(DataDirectory.desktopFolderName));
    } else {
      // 环境变量缺失时的降级路径：仍然要能用，且仍然不落工作目录
      expect(_isUnder(path, Directory.systemTemp.path), isTrue, reason: '降级应落临时目录，实际是 $path');
    }

    // 数据目录必须已经是**存在**的：`resolve()` 负责建出来，
    // 否则第一次保存会发现父目录不存在。
    expect(dir.existsSync(), isTrue, reason: '数据目录应已建好：$path');
  });

  test('数据目录名是目录、不是隐藏文件名（设置页要照着它展示"数据在哪"）', () {
    expect(DataDirectory.desktopFolderName, 'GuideLine');
    expect(DataDirectory.desktopFolderName.contains(Platform.pathSeparator), isFalse);
  });
}

/// [path] 是否在 [base] 里面（把两侧都归一化成绝对路径再比，避免大小写与分隔符差异）。
bool _isUnder(String path, String base) {
  final a = _norm(path);
  final b = _norm(base);
  return a == b || a.startsWith('$b${Platform.pathSeparator}');
}

String _norm(String path) {
  var p = path.replaceAll('/', Platform.pathSeparator);
  while (p.endsWith(Platform.pathSeparator)) {
    p = p.substring(0, p.length - 1);
  }
  return Platform.isWindows ? p.toLowerCase() : p;
}
