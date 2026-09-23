import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';
import '../core/json/store_file.dart';
import '../core/models/entity.dart';
import '../core/store/app_paths.dart';
import '../core/store/app_storage.dart';
import '../core/store/export_codec.dart';
import '../core/store/ui_prefs.dart';
import '../features/workspace.dart';
import '../platform/data_directory.dart';
import '../platform/data_transfer_platform.dart';

/// 应用装配与动作门面（**单机形态**）。
///
/// 职责：
///   · 启动时加载本地数据（含损坏隔离与「从备份自动恢复」的告警）；
///   · 把 `Workspace` 的业务动作包一层错误处理（`RuleViolation` → 可读文案）；
///   · 暴露数据目录、备份列表等设置页需要的信息。
///
/// **状态管理**：只有一个数据源 + 一个控制器，`ChangeNotifier` + `ListenableBuilder`
/// 已经足够，且零额外依赖。
class AppController extends ChangeNotifier {
  AppController({
    required this.storage,
    required this.workspace,
    required this.dataDirectory,
    required List<String> startupWarnings,
  }) : startupWarnings = List<String>.unmodifiable(startupWarnings);

  /// 从磁盘装配（唯一入口）。
  static Future<AppController> bootstrap({Directory? dataDirectoryOverride}) async {
    final dir = await DataDirectory.resolve(override: dataDirectoryOverride);
    final storage = AppStorage(AppPaths(dir));
    final report = storage.load();
    final workspace = Workspace.fromLoad(storage, report);
    return AppController(
      storage: storage,
      workspace: workspace,
      dataDirectory: dir,
      startupWarnings: buildWarnings(report),
    ).._loadBackgroundBytes();
  }

  final AppStorage storage;

  /// 恢复备份后会整体替换（UI 每次重建都读 `ws`，因此替换是安全的）
  Workspace workspace;

  final Directory dataDirectory;

  final List<String> startupWarnings;

  Workspace get ws => workspace;

  UiPrefs get prefs => workspace.prefs;

  int get projectCount => workspace.liveProjects.length;

  int get inspirationCount => workspace.inspirationInbox.length;

  int get eventCount => workspace.liveEvents.length;

  int get taskCount => workspace.liveTasks.length;

  int get archiveCount => workspace.archiveZone.totalCount;

  /// 已逾期：`due_at` 严格早于今天、未完成、未归档。
  int get overdueCount => workspace.tasksDueOnOrBefore(_yesterdayDate()).length;

  /// 今天及之前到期的待处理任务（含逾期）。
  int get dueCount => workspace.tasksDueOnOrBefore(Ids.todayDate()).length;

  static String _yesterdayDate() {
    final now = DateTime.now();
    return Ids.todayDate(DateTime(now.year, now.month, now.day - 1));
  }

  List<BackupEntry> get backups => storage.listBackups();

  int? get lastExportedAt => workspace.lastExportedAt;

  /// 「该导出了」的提醒阈值（天）。
  static const int exportReminderDays = 7;

  /// 从未导出，或距上次导出已超过 [exportReminderDays] 天。
  ///
  /// 没有云端之后，导出是数据离开这台手机的唯一通道，所以要主动提醒。
  bool get exportOverdue {
    final last = lastExportedAt;
    if (last == null) return true;
    final days = (Ids.nowMillis() - last) / Duration.millisecondsPerDay;
    return days >= exportReminderDays;
  }

  // ------------------------------------------------------------ 外观偏好

  /// 背景图字节（启动时读一次，换图时更新）。
  ///
  /// 缓存在内存里的原因：`Image.memory` 靠同一个 `Uint8List` 实例命中 Flutter 的
  /// 图片缓存；每次 build 都重新读盘会让背景反复闪烁。
  Uint8List? backgroundBytes;

  void _loadBackgroundBytes() {
    backgroundBytes = prefs.hasBackground ? storage.readBackgroundImage() : null;
  }

  /// 外观类偏好统一入口（主题 / 背景参数）。取色由 UI 层算好后一并传进来。
  void updatePrefs(UiPrefs next) {
    workspace.updatePrefs(next);
    notifyListeners();
  }

  /// 存下背景图并写回偏好；[seedHex] 是从图里取到的主色（可为空）。
  String? applyBackgroundImage(List<int> bytes, {String? seedHex}) {
    try {
      final file = storage.saveBackgroundImage(bytes);
      workspace.updatePrefs(
        prefs.copyWith(backgroundImagePath: file.path, backgroundSeedHex: seedHex),
      );
      backgroundBytes = Uint8List.fromList(bytes);
      notifyListeners();
      return null;
    } catch (error) {
      return '保存背景图失败：$error';
    }
  }

  void clearBackgroundImage() {
    storage.deleteBackgroundImage();
    workspace.updatePrefs(
      prefs.copyWith(backgroundImagePath: null, backgroundSeedHex: null),
    );
    backgroundBytes = null;
    notifyListeners();
  }

  /// 设置页展示的数据文件大小。
  String get storeFileSize {
    final file = storage.paths.storeFile;
    if (!file.existsSync()) return '—';
    final kb = file.lengthSync() / 1024;
    return kb < 1024 ? '${kb.toStringAsFixed(1)} KB' : '${(kb / 1024).toStringAsFixed(2)} MB';
  }

  /// 执行业务动作：把 `RuleViolation` 变成可读文案（返回 null 表示成功）。
  ///
  /// 也要接住**写盘失败**。业务动作的写法是「先改内存、再整份原子落盘」，
  /// 写盘失败时内存已经改了；如果让异常抛出去，界面只会记一条框架错误，
  /// 而用户看到的是「改成功了」—— 下次启动才发现改动没了。这种**假装成功**
  /// 比当场报错危险得多，所以磁盘类错误必须翻译成明确的失败文案。
  ///
  /// 只接 [FileSystemException]：那是磁盘/权限类问题。程序自身的 bug（类型错误等）
  /// 仍旧照常抛出，不在生产环境里被悄悄咽掉。
  String? run(void Function() action) {
    final before = workspace.snapshotInMemory();
    try {
      action();
      notifyListeners();
      return null;
    } on RuleViolation catch (violation) {
      return violation.message;
    } on FileSystemException catch (error) {
      // 内存退回动作前：宁可让界面"这次没生效"，也不能显示一个磁盘上没有的状态
      workspace.rollbackTo(before);
      notifyListeners();
      return '保存失败，这次改动没有写入磁盘（${error.message}）。请检查存储空间后重试。';
    }
  }

  void toggleCollapsed(String id, bool collapsed) {
    workspace.setCollapsed(id, collapsed);
    notifyListeners();
  }

  bool isCollapsed(String id) => prefs.isCollapsed(id);

  void setLastTab(int index) {
    workspace.setLastTab(index);
    notifyListeners();
  }

  /// 从备份恢复（**会先把当前数据轮转进备份**，因此恢复动作本身也可回退）。
  String? restoreBackup(String path) {
    try {
      final restored = storage.restoreFromBackup(path);
      workspace = Workspace.fromLoad(
        storage,
        LoadReport(
          store: restored,
          prefs: prefs,
          issues: DecodeIssues(),
          quarantinedPaths: const <String>[],
        ),
      );
      notifyListeners();
      return null;
    } catch (error) {
      return '恢复失败：$error';
    }
  }

  // ------------------------------------------------------------ 导出 / 导入

  /// 导出整份数据并交给系统分享面板。
  ///
  /// 分享是否成功**不影响导出本身**：文件已经落在应用私有目录里了，
  /// 用户取消分享只是没把它发出去。
  Future<({bool ok, String message})> exportAndShare() async {
    try {
      final now = Ids.nowMillis();
      final bytes = ExportCodec.encode(workspace.buildStoreFile(), exportedAt: now);
      final file = storage.writeExport(bytes, nowMillis: now);
      workspace.markExported(now);
      notifyListeners();

      final name = _fileNameOf(file.path);
      final shared = await DataTransferPlatform.shareFile(
        file.path,
        text: 'Guide Line 数据导出',
        subject: 'Guide Line 数据导出',
      );
      return (
        ok: true,
        message: shared ? '已导出并分享：$name' : '已导出到应用私有目录：$name',
      );
    } catch (error) {
      return (ok: false, message: '导出失败：$error');
    }
  }

  /// 用导入的数据**整体替换**当前数据。
  ///
  /// 替换前 [AppStorage.save] 会先把当前数据轮转进滚动备份，
  /// 所以"导错了文件"也能从「备份与恢复」里退回来。
  String? applyImport(StoreFile store) {
    try {
      storage.save(store);
      workspace = Workspace.fromLoad(
        storage,
        LoadReport(
          store: store,
          prefs: prefs,
          issues: DecodeIssues(),
          quarantinedPaths: const <String>[],
        ),
      );
      notifyListeners();
      return null;
    } catch (error) {
      return '导入失败：$error';
    }
  }

  static String _fileNameOf(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isEmpty ? path : parts.last;
  }

  /// 启动告警：把加载报告翻译成人能看懂的话。
  static List<String> buildWarnings(LoadReport report) {
    final warnings = <String>[];
    if (report.recoveredFromBackup != null) {
      warnings.add('主数据文件损坏，已从备份自动恢复');
    }
    if (report.quarantinedPaths.isNotEmpty) {
      warnings.add('检测到损坏文件（已隔离保留现场，未覆盖）：${report.quarantinedPaths.length} 个');
    }
    if (report.issues.errors.isNotEmpty) {
      warnings.add('解析时发现 ${report.issues.errors.length} 处问题，已按数据契约降级处理');
    }
    return warnings;
  }
}
