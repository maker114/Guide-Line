import 'dart:convert';
import 'dart:io';

import '../json/canonical.dart';
import '../json/document.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import 'app_paths.dart';
import 'atomic_file.dart';
import 'ui_prefs.dart';

/// 启动加载报告：把"读到了什么"与"哪里有问题"一起交给上层。
class LoadReport {
  const LoadReport({
    required this.store,
    required this.prefs,
    required this.issues,
    required this.quarantinedPaths,
    this.recoveredFromBackup,
  });

  final StoreFile store;
  final UiPrefs prefs;
  final DecodeIssues issues;

  /// 被隔离保留的损坏文件路径（**绝不静默重建空数据**）
  final List<String> quarantinedPaths;

  /// 若主文件损坏、自动用备份恢复，这里是所用备份的路径
  final String? recoveredFromBackup;

  bool get hasProblems => quarantinedPaths.isNotEmpty || issues.errors.isNotEmpty;
}

/// 单文件本地存储：**原子替换 + 备份轮转 + 损坏隔离/恢复**。
///
/// 这是本项目唯一的数据出口。没有云端，所以这几件事必须做扎实：
///   1. 写临时文件 → flush → rename（同目录 rename 原子）；
///   2. 每次保存前把旧文件轮转进滚动备份（保留最近 N 次）；
///   3. 每天第一份保存留下一个日快照（保留最近 N 天）——防"当天连续误操作把滚动备份也覆盖了"；
///   4. 主文件损坏时**隔离现场**，并能用最近的备份自动恢复。
class AppStorage {
  AppStorage(this.paths);

  final AppPaths paths;

  // ---------------------------------------------------------------- 读

  LoadReport load({int? nowMillis}) {
    paths.ensureDirectories();
    AtomicFile.cleanupTmp(paths.managedFiles);

    final issues = DecodeIssues();
    final quarantined = <String>[];
    final stamp = nowMillis ?? DateTime.now().millisecondsSinceEpoch;

    var store = StoreFile.empty();
    String? recoveredFrom;

    final file = paths.storeFile;
    if (file.existsSync()) {
      final text = file.readAsStringSync(encoding: utf8);
      final parsed = _tryParse(text, issues);
      if (parsed != null) {
        store = parsed;
      } else {
        // 主文件读不了 → 隔离现场，然后尝试最近的备份
        issues.error('主数据文件无法解析 —— 已隔离保留现场');
        quarantined.add(AtomicFile(file).quarantine(stamp));
        final recovery = _loadNewestBackup(issues);
        if (recovery != null) {
          store = recovery.store;
          recoveredFrom = recovery.path;
          issues.warn('已从备份恢复：${recovery.path}');
        }
      }
    }

    return LoadReport(
      store: store,
      prefs: _readPrefs(),
      issues: issues,
      quarantinedPaths: quarantined,
      recoveredFromBackup: recoveredFrom,
    );
  }

  StoreFile? _tryParse(String text, DecodeIssues issues) {
    try {
      Canonical.decode(text);
    } catch (_) {
      return null;
    }
    final parsed = StoreFile.parse(text, issues);
    // 解析成功但字段全空时，视为"空数据"而不是损坏（新装应用的文件可能是空壳）
    return parsed;
  }

  ({StoreFile store, String path})? _loadNewestBackup(DecodeIssues issues) {
    final candidates = <File>[
      for (var i = 1; i <= AppPaths.rollingBackupCount; i += 1) paths.rollingBackup(i),
      ..._dailyBackups(),
    ].where((f) => f.existsSync()).toList();

    // 越新的排在前面：滚动备份 1 最新；日快照按文件名倒序
    candidates.sort((a, b) {
      final aRolling = _rollingIndex(a);
      final bRolling = _rollingIndex(b);
      if (aRolling != null && bRolling != null) return aRolling.compareTo(bRolling);
      if (aRolling != null) return -1;
      if (bRolling != null) return 1;
      return b.path.compareTo(a.path);
    });

    for (final candidate in candidates) {
      try {
        final text = candidate.readAsStringSync(encoding: utf8);
        final parsed = StoreFile.parse(text, DecodeIssues());
        if (parsed.documents.isNotEmpty) {
          return (store: parsed, path: candidate.path);
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  int? _rollingIndex(File file) {
    final name = file.uri.pathSegments.last;
    if (!name.startsWith(AppPaths.backupPrefix)) return null;
    final digits = name
        .substring(AppPaths.backupPrefix.length)
        .replaceAll('.json', '');
    return int.tryParse(digits);
  }

  List<File> _dailyBackups() {
    if (!paths.directory.existsSync()) return <File>[];
    final files = paths.directory
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith(AppPaths.dailyPrefix))
        .toList(growable: false);
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  // ---------------------------------------------------------------- 写

  /// 保存全部数据：**先轮转备份，再原子替换主文件**。
  void save(StoreFile store, {int? nowMillis}) {
    paths.ensureDirectories();
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final stamped = store.copyWith(savedAt: now);

    _rotateBackups(now);
    AtomicFile(paths.storeFile).writeText(stamped.toCanonicalText());
  }

  void savePrefs(UiPrefs prefs) {
    paths.ensureDirectories();
    AtomicFile(paths.prefsFile).writeText(prefs.toCanonicalText());
  }

  /// 滚动备份 + 日快照。
  void _rotateBackups(int now) {
    final store = paths.storeFile;
    if (!store.existsSync()) return;

    // 日快照：今天还没有快照时先留一份（在轮转之前，保证是"今天开始时的状态"）
    final today = _yyyymmdd(now);
    final todayFile = paths.dailyBackup(today);
    if (!todayFile.existsSync()) {
      _copyFile(store, todayFile);
      _pruneDaily();
    }

    // 滚动：backup.(n) → backup.(n+1)，最后把主文件复制成 backup.1
    for (var i = AppPaths.rollingBackupCount - 1; i >= 1; i -= 1) {
      final from = paths.rollingBackup(i);
      if (!from.existsSync()) continue;
      _copyFile(from, paths.rollingBackup(i + 1));
    }
    _copyFile(store, paths.rollingBackup(1));
  }

  void _pruneDaily() {
    final dailies = _dailyBackups();
    for (var i = AppPaths.dailyBackupCount; i < dailies.length; i += 1) {
      try {
        dailies[i].deleteSync();
      } catch (_) {
        // 清理失败不影响正确性
      }
    }
  }

  void _copyFile(File from, File to) {
    try {
      final bytes = from.readAsBytesSync();
      AtomicFile(to).writeBytes(bytes);
    } catch (_) {
      // 备份失败不能阻断主流程（主文件仍会被原子写入）
    }
  }

  String _yyyymmdd(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}';
  }

  // ---------------------------------------------------------------- 备份管理

  /// 可用的备份列表（新 → 旧），供设置页展示与恢复。
  List<BackupEntry> listBackups() {
    final entries = <BackupEntry>[];

    for (var i = 1; i <= AppPaths.rollingBackupCount; i += 1) {
      final file = paths.rollingBackup(i);
      if (file.existsSync()) {
        entries.add(BackupEntry(
          path: file.path,
          label: '上一份（$i 次保存前）',
          kind: BackupKind.rolling,
          sizeBytes: file.lengthSync(),
          modifiedAt: file.lastModifiedSync().millisecondsSinceEpoch,
        ));
      }
    }
    for (final file in _dailyBackups()) {
      final name = file.uri.pathSegments.last;
      final date = name
          .substring(AppPaths.dailyPrefix.length)
          .replaceAll('.json', '');
      entries.add(BackupEntry(
        path: file.path,
        label: '日快照 $date',
        kind: BackupKind.daily,
        sizeBytes: file.lengthSync(),
        modifiedAt: file.lastModifiedSync().millisecondsSinceEpoch,
      ));
    }
    return entries;
  }

  /// 从备份恢复：先把**当前**主文件轮转走（避免恢复动作本身造成不可逆），再替换。
  StoreFile restoreFromBackup(String backupPath, {int? nowMillis}) {
    final backup = File(backupPath);
    if (!backup.existsSync()) {
      throw StateError('备份不存在：$backupPath');
    }
    final issues = DecodeIssues();
    final parsed = StoreFile.parse(backup.readAsStringSync(encoding: utf8), issues);
    if (parsed.documents.isEmpty) {
      throw StateError('备份内容无法解析：$backupPath');
    }
    _rotateBackups(nowMillis ?? DateTime.now().millisecondsSinceEpoch);
    AtomicFile(paths.storeFile).writeText(parsed.toCanonicalText());
    return parsed;
  }

  /// 导出目录（供"导出/分享"使用）。
  Directory ensureExportsDir() {
    final dir = paths.exportsDir;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 导出保留份数：导出文件是完整副本，留最近几份够用于"手滑选错目标"。
  static const int exportKeepCount = 5;

  /// 写一份导出文件，返回它。
  ///
  /// 放在**应用私有目录**里而不是外部存储：分享面板会通过 FileProvider 授权读取，
  /// 不需要申请存储权限，也不会把数据留在公共目录里被别的 App 扫到。
  File writeExport(List<int> bytes, {required int nowMillis}) {
    final dir = ensureExportsDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_exportName(nowMillis)}');
    AtomicFile(file).writeBytes(bytes);
    _pruneExports();
    return file;
  }

  /// 现有的导出文件（新 → 旧）。
  List<File> listExports() {
    if (!paths.exportsDir.existsSync()) return <File>[];
    final files = paths.exportsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('guideline-'))
        .toList(growable: false);
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  void _pruneExports() {
    final files = listExports();
    for (var i = exportKeepCount; i < files.length; i += 1) {
      try {
        files[i].deleteSync();
      } catch (_) {
        // 清理失败不影响本次导出
      }
    }
  }

  /// `guideline-YYYYMMDD-HHmmss.json.gz`
  String _exportName(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${d.year}${two(d.month)}${two(d.day)}';
    final time = '${two(d.hour)}${two(d.minute)}${two(d.second)}';
    return 'guideline-$date-$time.json.gz';
  }

  // ---------------------------------------------------------------- 偏好

  UiPrefs _readPrefs() {
    final file = paths.prefsFile;
    if (!file.existsSync()) return UiPrefs.empty;
    try {
      final decoded = Canonical.decode(file.readAsStringSync(encoding: utf8));
      if (decoded is Map) return UiPrefs.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      // 视图偏好损坏无关紧要，直接重置
    }
    return UiPrefs.empty;
  }

  /// 便于测试与调试：把当前数据写成某份集合的规范文本。
  static String canonicalTextOf(Document document) => document.toCanonicalText();
}

enum BackupKind { rolling, daily }

class BackupEntry {
  const BackupEntry({
    required this.path,
    required this.label,
    required this.kind,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final String label;
  final BackupKind kind;
  final int sizeBytes;
  final int modifiedAt;
}
