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
    );
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

  /// 设置页展示的数据文件大小。
  String get storeFileSize {
    final file = storage.paths.storeFile;
    if (!file.existsSync()) return '—';
    final kb = file.lengthSync() / 1024;
    return kb < 1024 ? '${kb.toStringAsFixed(1)} KB' : '${(kb / 1024).toStringAsFixed(2)} MB';
  }

  /// 执行业务动作：把 `RuleViolation` 变成可读文案（返回 null 表示成功）。
  String? run(void Function() action) {
    try {
      action();
      notifyListeners();
      return null;
    } on RuleViolation catch (violation) {
      return violation.message;
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
