import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models/entity.dart';
import '../core/models/enums.dart';
import '../core/store/local_paths.dart';
import '../core/store/local_store.dart';
import '../features/portability.dart';
import '../features/workspace.dart';
import '../platform/data_directory.dart';
import '../sync/sync_engine.dart';

/// 应用装配与动作门面。
///
/// 职责：
///   · 启动时加载本地数据（含损坏文件隔离的告警）；
///   · 把 `Workspace` 的业务动作包一层错误处理（`RuleViolation` → 可读文案，不抛给 UI）；
///   · 暴露同步状态（未配置云端时显示"本地模式"）；
///   · 导出 / 导入。
///
/// **状态管理选型说明**：设计文档 §6 写的是 Riverpod/Provider。
/// 目前只有一个数据源 + 一个控制器，`ChangeNotifier` + `ListenableBuilder` 已经足够，
/// 且**零新增依赖**；真要拆细粒度状态时再迁移（迁移面只在本文件与 UI 层）。
class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.workspace,
    required this.dataDirectory,
    this.engine,
    List<String> startupWarnings = const <String>[],
    SyncStatus? initialSyncStatus,
  })  : _startupWarnings = List<String>.of(startupWarnings),
        _syncStatus = initialSyncStatus ?? const SyncStatus.idle();

  /// 从磁盘装配（唯一入口）。
  factory AppController.bootstrap({Directory? dataDirectoryOverride}) {
    final dir = DataDirectory.resolve(override: dataDirectoryOverride);
    final store = LocalStore(LocalPaths(dir));
    final report = store.load();
    final workspace = Workspace.fromLoad(store, report);

    final warnings = <String>[];
    if (report.hasCorruptDocument) {
      warnings.add(
        '检测到损坏的数据文件（已隔离保留现场，未做任何覆盖）：'
        '${report.quarantinedPaths.length} 个',
      );
    }
    if (report.issues.errors.isNotEmpty) {
      warnings.add('解析时发现 ${report.issues.errors.length} 处问题，已按契约降级处理');
    }

    return AppController(
      store: store,
      workspace: workspace,
      dataDirectory: dir,
      startupWarnings: warnings,
    );
  }

  final LocalStore store;
  final Workspace workspace;
  final Directory dataDirectory;

  /// 未配置云端时为 null —— v1.0.0 以"本地模式"运行（云端后端待定）。
  final SyncEngine? engine;

  final List<String> _startupWarnings;
  SyncStatus _syncStatus;

  List<String> get startupWarnings => List<String>.unmodifiable(_startupWarnings);

  SyncStatus get syncStatus => _syncStatus;

  bool get hasCloud => engine != null;

  Workspace get ws => workspace;

  // ---------------------------------------------------------------- 查询转发

  int get projectCount => workspace.liveProjects.length;

  int get inspirationCount => workspace.inspirationInbox.length;

  int get eventCount => workspace.liveEvents.length;

  int get taskCount => workspace.liveTasks.length;

  int get archiveCount => workspace.archiveZone.totalCount;

  // ---------------------------------------------------------------- 动作门面

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

  // ---------------------------------------------------------------- 导出 / 导入

  /// 导出到指定文件；返回写入的路径。
  String exportTo(String filePath) {
    final bytes = Portability.exportBytes(workspace, appVersion: AppInfo.version);
    final file = File(filePath);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
    return file.path;
  }

  /// 默认导出路径：`<数据目录>/exports/guideline-export-<时间>.json.gz`
  String defaultExportPath() {
    final name = Portability.suggestedFileName(DateTime.now().millisecondsSinceEpoch);
    return '${dataDirectory.path}${Platform.pathSeparator}exports${Platform.pathSeparator}$name';
  }

  /// 预检导入包（不修改数据）。
  ImportPreviewResult previewImport(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    final issues = DecodeIssues();
    final bundle = Portability.decodeBytes(bytes, issues);
    if (bundle == null) {
      return ImportPreviewResult(error: issues.errors.join('；'), decisions: const <ImportDecision>[]);
    }
    return ImportPreviewResult(
      error: null,
      decisions: Portability.preview(workspace, bundle),
      bundle: bundle,
    );
  }

  /// 应用导入；冲突项按 [choices] 处理。
  ImportReport? applyImport(
    String filePath, {
    Map<DocName, ImportConflictChoice> choices = const <DocName, ImportConflictChoice>{},
  }) {
    final bytes = File(filePath).readAsBytesSync();
    final issues = DecodeIssues();
    final bundle = Portability.decodeBytes(bytes, issues);
    if (bundle == null) return null;
    final report = Portability.apply(workspace, bundle, choices: choices);
    notifyListeners();
    return report;
  }

  /// 更新同步状态（由同步引擎回调 / UI 触发）。
  void updateSyncStatus(SyncStatus status) {
    _syncStatus = status;
    notifyListeners();
  }

  /// 手动触发一次同步（未配置云端时返回提示）。
  Future<String?> syncNow() async {
    final current = engine;
    if (current == null) return '尚未配置云端同步（v1.0.0 为本地模式）';
    final report = await current.sync();
    _syncStatus = report.status;
    notifyListeners();
    if (report.ok) {
      return null;
    }
    return report.status.label;
  }

  void toggleCollapsed(String id, bool collapsed) {
    workspace.setCollapsed(id, collapsed);
    notifyListeners();
  }

  bool isCollapsed(String id) => workspace.prefs.isCollapsed(id);
}

/// 导入预检结果。
class ImportPreviewResult {
  const ImportPreviewResult({required this.error, required this.decisions, this.bundle});

  final String? error;
  final List<ImportDecision> decisions;
  final ExportBundle? bundle;

  bool get ok => error == null;

  bool get hasConflict =>
      decisions.any((d) => d.action == ImportAction.conflict);

  int get changeCount => decisions
      .where((d) => d.action == ImportAction.takeIncoming)
      .length;
}
