import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 平台适配层：**唯一允许出现平台判断的地方**（ADR-024）。
///
/// 数据一律放在**应用私有目录**（其它程序读不到；但**卸载会被系统清除**，
/// 所以必须配合导出备份，见《定义与边界》§9）。三端各自的落点：
///
/// | 平台 | 位置 | 由谁决定 |
/// | --- | --- | --- |
/// | Android / iOS | 应用支持目录下的 `guideline/` | `path_provider`（`getApplicationSupportDirectory`） |
/// | Windows | `%LOCALAPPDATA%\GuideLine` | 本文件（**不引 `path_provider` 的桌面实现**） |
///
/// 电脑端为什么不用 `path_provider`：它返回的是 `%APPDATA%\com.maker\guideline`，
/// 那家在漫游目录（`Roaming`）里 —— 企业域账户下会被登录脚本同步来同步去，
/// 而 Guideline 的主文件是**整份重写**的（见 `AppPaths`），
/// 一把几 MB 的文件天天参与漫游纯属自找麻烦。所以按 ADR 口径取**本机私有**的
/// `%LOCALAPPDATA%`（**不随账户漫游**），并且刻意不引 `path_provider_windows`，
/// 少一个插件、少一条原生依赖链。
///
/// 曾经的写法是"非 Android/iOS 一律落到 `Directory.current/data`" ——
/// 那在真机上会写进**仓库目录**（开发时看着方便，打包成 exe 后 `Directory.current`
/// 可能是任意位置，用户双击运行就会在程序旁边堆出一个 `data\`）。
class DataDirectory {
  const DataDirectory._();

  /// 电脑端数据目录名（`%LOCALAPPDATA%\GuideLine`）。
  static const String desktopFolderName = 'GuideLine';

  /// 解析数据目录：优先显式传入（测试用），否则按平台规则。
  static Future<Directory> resolve({Directory? override}) async {
    if (override != null) return override;

    if (Platform.isAndroid || Platform.isIOS) {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}guideline');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }

    if (Platform.isWindows) return _resolveWindows();

    // 兜底：既不是手机也不是 Windows（本机上的单元测试宿主、以及将来可能的
    // Linux / macOS）。仍然落应用私有位置，**绝不落当前工作目录**。
    // 环境变量一个都拿不到时退到系统临时目录 —— 同样是为了"降级但仍能启动"。
    final base = _env('LOCALAPPDATA') ?? _env('XDG_DATA_HOME') ?? _env('HOME') ?? Directory.systemTemp.path;
    final fallback = Directory(_join(base, 'guideline'));
    if (!fallback.existsSync()) fallback.createSync(recursive: true);
    return fallback;
  }

  /// `%LOCALAPPDATA%\GuideLine`；环境变量缺失或目录建不出来时退到临时目录。
  ///
  /// **降级也要能用**：拿不到 `LOCALAPPDATA` 时如果直接抛，程序连启动都做不到；
  /// 退到 `Directory.systemTemp` 至少能跑起来并把数据写到设置页能看见的地方。
  static Directory _resolveWindows() {
    final base = _env('LOCALAPPDATA');
    if (base != null && base.isNotEmpty) {
      final dir = Directory(_join(base, desktopFolderName));
      if (_ensure(dir)) return dir;
    }
    final temp = Directory(_join(Directory.systemTemp.path, desktopFolderName));
    _ensure(temp);
    return temp;
  }

  /// 建目录；建不出来（权限 / 磁盘满）返回 false 让调用方降级，不抛。
  static bool _ensure(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static String? _env(String name) => Platform.environment[name];

  static String _join(String? base, String name) =>
      '${base ?? ''}${Platform.pathSeparator}$name';
}

/// 应用元信息（与 `pubspec.yaml` 的 `version:` 一致，由 `test/core/version_test.dart` 守着）。
class AppInfo {
  const AppInfo._();

  static const String displayName = 'Guide Line';

  static const String version = '2.7.3';

  static const String buildNumber = '83';

  /// 界面与导出里展示的完整版本（`1.8.5+37`）。
  ///
  /// 只留这一个源头：以前 `pubspec.yaml`、关于对话框、更多页各写一遍，
  /// 发版时必然漏一个（1.0.0 就是漏到 1.1.0 才发现），所以这里拼出来给界面用。
  /// **有测试守着**：`test/core/version_test.dart` 读 `pubspec.yaml` 的 `version:` 行，
  /// 与这里的两个常量对照 —— 漏改哪一处都会让测试变红，不再靠人记得。
  static const String versionLabel = '$version+$buildNumber';

  /// Android 包名（真正的权威在 `android/app/build.gradle.kts`）。
  static const String packageName = 'com.maker.guideline';
}
