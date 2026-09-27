import 'dart:io';

/// 本地文件布局（**手机端单文件存储**）。
///
/// 平台层只负责给出**应用私有数据目录**（Android 上由 `path_provider` 提供），
/// core 层只认目录 + 文件名，因此可以纯 Dart 测试。
class AppPaths {
  const AppPaths(this.directory);

  final Directory directory;

  /// 主数据文件（全部数据都在这一份里）
  static const String storeFileName = 'guideline.json';

  /// 界面偏好（改动频繁，独立成小文件，避免为折叠一个节点重写整份数据）
  static const String prefsFileName = 'ui_prefs.json';

  /// 最近 N 次保存的滚动备份
  static const String backupPrefix = 'guideline.backup.';
  static const int rollingBackupCount = 10;

  /// 每天第一份保存留下一个日快照，保留最近 N 天
  static const String dailyPrefix = 'guideline.daily.';
  static const int dailyBackupCount = 7;

  /// 损坏现场的隔离文件（`<名>.corrupt.<时间戳>`）最多留几份。
  ///
  /// 隔离区是"最后一道人工求救通道"，但也不能无限堆积 —— 早先的实现只加不清，
  /// 长期占用应用私有目录，而用户在设置页里看不到也删不掉（P1-7）。
  static const int quarantineKeepCount = 5;

  static const String exportsDirName = 'exports';

  /// 背景图：从相册选进来的那张会被拷到这里，
  /// 免得原图被删掉或移走之后背景就失效了。
  static const String backgroundDirName = 'background';

  File get storeFile => File(_join(storeFileName));

  File get prefsFile => File(_join(prefsFileName));

  Directory get backgroundDir => Directory(_join(backgroundDirName));

  /// 背景图统一叫 `background.img` —— 解码器按内容判格式，不靠扩展名。
  File get backgroundImageFile =>
      File(_join('$backgroundDirName${Platform.pathSeparator}background.img'));

  /// 滚动备份：索引 1 表示"上一份"，越大越旧。
  File rollingBackup(int index) => File(_join('$backupPrefix$index.json'));

  /// 日快照：`guideline.daily.20260922.json`
  File dailyBackup(String yyyymmdd) => File(_join('$dailyPrefix$yyyymmdd.json'));

  Directory get exportsDir => Directory(_join(exportsDirName));

  List<File> get managedFiles => <File>[storeFile, prefsFile, backgroundImageFile];

  void ensureDirectories() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
  }

  String _join(String name) => '${directory.path}${Platform.pathSeparator}$name';

  /// 供设置页展示"数据在哪"。
  String describe() => directory.path;
}
