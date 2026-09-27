import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 平台适配层：**唯一允许出现平台判断的地方**（ADR-024）。
///
/// 手机端数据放在**应用私有目录**（其它 App 读不到；但**卸载会被系统清除**，
/// 所以必须配合导出备份，见《手机端（Android 单机）v1.0 计划》§4）。
class DataDirectory {
  const DataDirectory._();

  /// 解析数据目录：优先显式传入（测试用），否则按平台规则。
  static Future<Directory> resolve({Directory? override}) async {
    if (override != null) return override;

    if (Platform.isAndroid || Platform.isIOS) {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}guideline');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }

    // 桌面运行 / 测试时的兜底（正式平台是 Android）
    return Directory('${Directory.current.path}${Platform.pathSeparator}data');
  }
}

/// 应用元信息（与 §10.2 的版本规则一致）。
class AppInfo {
  const AppInfo._();

  static const String displayName = 'Guide Line';

  static const String version = '1.5.4';

  static const String buildNumber = '28';

  /// 界面与导出里展示的完整版本（`1.5.4+28`）。
  ///
  /// 只留这一个源头：以前 `pubspec.yaml`、关于对话框、更多页各写一遍，
  /// 发版时必然漏一个（1.0.0 就是漏到 1.1.0 才发现），所以这里拼出来给界面用。
  /// **有测试守着**：`test/core/version_test.dart` 读 `pubspec.yaml` 的 `version:` 行，
  /// 与这里的两个常量对照 —— 漏改哪一处都会让测试变红，不再靠人记得。
  static const String versionLabel = '$version+$buildNumber';

  /// Android 包名（真正的权威在 `android/app/build.gradle.kts`）。
  static const String packageName = 'com.maker.guideline';
}
