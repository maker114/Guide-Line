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

  /// **会用 `.tmp` 中转的文件（给 `cleanupTmp` 用）—— 比 [managedFiles] 宽。**
  ///
  /// 为什么不能直接往 [managedFiles] 里加：那个清单的语义是"**这是数据文件**"，
  /// 别处会照着它判断"哪些东西要进轮转 / 导出 / 备份"（见 `app_storage.dart` 里
  /// 那句"省得被 `managedFiles` 当成数据文件看待"）。私有存档（实现计划正文、
  /// 重置快照、同步记录）**不是数据**，加进去会改变那些判断。
  ///
  /// 但它**确实是原子写的** —— 主文件、偏好、背景图、日快照、实现计划正文、
  /// 重置快照、同步记录，外加 `exports/` 子目录里的导出与交接说明，
  /// 所以崩溃时一样会留下 `.tmp`：清理要覆盖到，判定"是不是数据"则不要。
  /// 两件事用一个清单表达过，就会顾此失彼。
  ///
  /// （2026-10-01 更正：这段原来写"7 处"、并暗示列清单就够。实际是 **10 处**，
  /// 而 `exports/` 那两处**列清单的思路必然漏掉** —— 它们现在由
  /// `AtomicFile.cleanupTmpIn(paths.exportsDir)` 按目录扫名字来清。）
  ///
  /// 日快照是**每天一个新名字**，所以这里现扫目录（`managedFiles` 那种写死的
  /// 三条做不到）。
  ///
  /// ⚠️ 扫到的可能是**残留的 `.tmp` 本身**（崩溃时"正式文件还没就位"，
  /// 于是目录里只有 `guideline.daily.20260906.json.tmp`）—— 所以两种都要收进来。
  /// 第一次我写的是"只收 `.json` 结尾的"，于是把那种残留**恰好排除掉**，
  /// 而那正是最该清的一种（用例当场红了）。
  List<File> get atomicWrittenFiles {
    final out = <File>[...managedFiles];
    if (!directory.existsSync()) return out;
    for (final entry in directory.listSync()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!name.startsWith(dailyPrefix)) continue;
      // 正式文件（`…json`）→ 清理时会去找它的 `.tmp`；
      // 残留的 `.tmp` 本身 → 直接作为候选（它的 `.tmp.tmp` 不存在，无副作用）
      if (name.endsWith('.json')) {
        out.add(entry);
      } else if (name.endsWith('.json.tmp')) {
        // ⚠️ **必须用 `_join` 拼回绝对路径**：第一次我写的是
        // `File(name.substring(...))` —— 那是**相对路径**，`tmpOf` 拼出来的
        // `…tmp` 会从进程工作目录去找，`existsSync()` 为假，
        // 于是"清理"**静默什么都没做**（探针打出来才看见）。
        out.add(File(_join(name.substring(0, name.length - '.tmp'.length))));
      }
    }
    return out;
  }

  void ensureDirectories() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
  }

  String _join(String name) => '${directory.path}${Platform.pathSeparator}$name';

  /// 供设置页展示"数据在哪"。
  String describe() => directory.path;
}
