import 'dart:io';

/// 平台适配层：**唯一允许出现平台判断的地方**（ADR-024）。
///
/// v1.0.0 只做 Windows，因此这里用 `%APPDATA%` 定位数据目录，
/// **不引入 path_provider**（少一个依赖、少一层构建风险）。
/// 将来上手机端时，只需在这里加一个 `path_provider` 分支，上层代码零改动。
class DataDirectory {
  const DataDirectory._();

  static const String appFolderName = 'GuideLine';

  /// 解析数据目录：优先显式传入（测试用），否则按平台规则。
  static Directory resolve({Directory? override}) {
    if (override != null) return override;

    final env = Platform.environment;
    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory('$appData${Platform.pathSeparator}$appFolderName');
      }
      final userProfile = env['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return Directory(
          '$userProfile${Platform.pathSeparator}AppData${Platform.pathSeparator}Roaming'
          '${Platform.pathSeparator}$appFolderName',
        );
      }
    }

    // 其它平台（或环境变量缺失）：落到可执行文件同级的 data 目录，保证总能跑起来
    return Directory('${Directory.current.path}${Platform.pathSeparator}data');
  }

  /// 便于设置页展示"数据在哪"。
  static String describe(Directory dir) => dir.path;
}

/// 应用元信息（版本号与 §10.2 的版本规则保持一致）。
class AppInfo {
  const AppInfo._();

  static const String displayName = 'Guide Line';

  static const String technicalName = 'GuideLine';

  static const String version = '1.0.0';

  static const String buildNumber = '1';
}
