import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../json/canonical.dart';
import '../json/document.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import '../models/enums.dart';
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
///   2. 主文件**改一下就写**，备份轮转按"编辑会话 / 最小间隔"节流（见 [save]）；
///   3. 每天第一份轮转留下一个日快照（保留最近 N 天）——防"当天连续误操作把滚动备份也覆盖了"；
///   4. 主文件损坏时**隔离现场**，并能用最近的备份自动恢复。
///
/// 第 2 条是 2026-09-26 改的口径：原来每次保存都轮转，连续编辑一分钟就把十份
/// 滚动备份挤光了 —— 备份该代表"一段完整操作"，而不是"第几次保存"。
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
    if (!file.existsSync()) {
      // 主文件**不在**，并不等于「全新安装」。
      // 上次有可能正好死在「删旧文件 → 改名」那一步（或文件被外部清理掉了）。
      // 只要还有备份，就必须恢复 + 明确告警 —— 全新安装没有任何备份，走不到这里。
      final recovery = _loadNewestBackup(issues);
      if (recovery != null) {
        store = recovery.store;
        recoveredFrom = recovery.path;
        issues.error('主数据文件不存在 —— 已从备份恢复：${recovery.path}');
        _writeBackRecovered(store, stamp, issues);
      }
    } else {
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
          _writeBackRecovered(store, stamp, issues);
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

  /// 把恢复出来的数据**立刻写回主文件**。
  ///
  /// 不写回的话，这次恢复只活在内存里：用户没做任何改动就退出，下次启动主文件依旧不存在，
  /// 而 `load` 对「没有主文件」的处理是**空数据且不告警** —— 界面上就是一个崭新的空库，
  /// 看起来等同于「数据全没了」。真机实测正是这个现象，所以恢复必须落盘。
  ///
  /// 这里**不做备份轮转**：主文件刚刚才被隔离走，没有「上一份」可轮转，
  /// 而且这一步的目的只是让状态自愈，不该再动备份窗口。
  void _writeBackRecovered(StoreFile store, int now, DecodeIssues issues) {
    try {
      AtomicFile(paths.storeFile).writeText(store.copyWith(savedAt: now).toCanonicalText());
    } catch (error) {
      issues.error('从备份恢复后写回主文件失败：$error');
    }
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

  /// 不在编辑会话时的轮转**最小间隔**：5 分钟。
  ///
  /// 它是"节流"不是"定时"：只要距上次轮转够久，下一笔保存就会留下新的备份。
  /// 取值理由：手机上的连续编辑（改个名、勾一条、补一句）通常集中在几分钟内，
  /// 这段时间里留一份就够回退；而 5 分钟又短到"随手改改"也不至于整天不落后备。
  static const int rotateMinIntervalMillis = 5 * 60 * 1000;

  /// 是否正处在一段编辑会话里（进编辑页面 → 离开）。
  bool get inEditSession => _inEditSession;

  bool _inEditSession = false;

  /// 本会话是否已经轮转过 —— **一段会话只留一份备份**，即"进页面之前"的那份。
  bool _rotatedInSession = false;

  /// 上次轮转的时刻；非会话期间的节流以它为基准（`null` = 还没轮转过）。
  int? _lastRotateAt;

  /// 进入编辑会话：**只置标记**，不写盘、也不轮转。
  ///
  /// 轮转刻意推迟到本会话的**第一笔写入**：这样"进页面什么都没改就退出"
  /// 不会留下任何备份，而留下的那一份正好是"进页面之前"的状态 ——
  /// 备份的含义于是变成"一段完整操作之前的存档"。
  ///
  /// 已经在会话中时什么都不做：详情页里再推开一层、或调用方重复调用，
  /// 都不该把"本会话已轮转过"重置掉，否则一段操作会散成好几份备份。
  void beginEditSession() {
    if (_inEditSession) return;
    _inEditSession = true;
    _rotatedInSession = false;
  }

  /// 离开编辑会话：清标记，并把节流基准推到此刻。
  ///
  /// 推基准是有意的：刚从编辑页面出来时，主文件里已经有一份刚轮转过的备份了，
  /// 紧接着的散点保存没必要再挤一份进去。
  void endEditSession() {
    _inEditSession = false;
    _rotatedInSession = false;
    _lastRotateAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 保存全部数据：**按策略先轮转备份，再原子替换主文件**。
  ///
  /// 三条路收敛到同一个 `_rotateNow`，差别只在"该不该轮转"：
  ///   · [forceRotate] —— **用户显式要求现在留一份**（手动快照 / 批量操作前 / 恢复），
  ///     跳过全部节流，按老语义直接轮转；
  ///   · **编辑会话中** —— 只在第一笔写入前轮转一次。此刻主文件还是"进页面之前"
  ///     的内容，这一份才是整段操作的存档；之后的每一笔写入只写主文件；
  ///   · **其余** —— 按 [rotateMinIntervalMillis] 节流。
  ///
  /// 主文件本身**照旧每次都写**：节流只作用于备份，"防断电 / 防杀进程"这条不能松。
  void save(StoreFile store, {int? nowMillis, bool forceRotate = false}) {
    paths.ensureDirectories();
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final stamped = store.copyWith(savedAt: now);

    if (forceRotate) {
      _rotateNow(now);
    } else if (_inEditSession) {
      if (!_rotatedInSession) _rotateNow(now);
    } else if (_rotateDue(now)) {
      _rotateNow(now);
    }

    AtomicFile(paths.storeFile).writeText(stamped.toCanonicalText());
  }

  /// 非会话期间该不该轮转：从没轮转过，或距上次已超过最小间隔。
  bool _rotateDue(int now) {
    final last = _lastRotateAt;
    if (last == null) return true;
    // 取绝对值：设备时钟被往回改（或调用方给了更早的时间戳）时，
    // 不该把轮转永久锁死 —— 那是"备份再也不更新"，比多留一份危险得多。
    return (now - last).abs() >= rotateMinIntervalMillis;
  }

  /// 轮转一次并记账（会话内 / 非会话 / 强制三条路都收敛到这里）。
  void _rotateNow(int now) {
    _rotateBackups(now);
    _lastRotateAt = now;
    _rotatedInSession = true;
  }

  void savePrefs(UiPrefs prefs) {
    paths.ensureDirectories();
    AtomicFile(paths.prefsFile).writeText(prefs.toCanonicalText());
  }

  /// 滚动备份 + 日快照（**纯机械部分**：该不该轮转由调用方决定，见 [save]）。
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

    // 滚动：backup.(n) → backup.(n+1)。
    //
    // 移位用**改名**而不是复制：复制的话每次保存都要把 9 份备份整份搬一遍，
    // 代价是 9×文件大小（几 MB 的数据就是几十 MB 的无谓写入，还是每次保存都来一遍）。
    // 改名只动目录项，代价与文件大小无关。
    for (var i = AppPaths.rollingBackupCount - 1; i >= 1; i -= 1) {
      final from = paths.rollingBackup(i);
      if (!from.existsSync()) continue;
      _shiftFile(from, paths.rollingBackup(i + 1));
    }
    // 最后一步必须是复制：主文件还要留着
    _copyFile(store, paths.rollingBackup(1));
  }

  /// 备份移位：优先改名（O(1)），不行再退回复制。
  ///
  /// 备份永远不该阻断主流程，所以两条路都失败也只是这一次少一份备份。
  void _shiftFile(File from, File to) {
    try {
      if (to.existsSync()) to.deleteSync();
      from.renameSync(to.path);
    } catch (_) {
      _copyFile(from, to);
    }
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
  ///
  /// 标签给的是**时间点 + 记录条数**，不再写"（N 次保存前）"：轮转改成按编辑会话
  /// 节流之后，"第几次保存"已经没有意义了，而"这条备份里有多少条记录"能让人
  /// 一眼看出哪一份更接近自己想要的（条数骤降的那一份往往就是误删之前）。
  ///
  /// 代价说明：为了数条数，这里会**解析每一份备份**。窗口是固定的
  /// （滚动 10 份 + 日快照 7 份），所以代价有上界，且只在这一页被打开时发生。
  List<BackupEntry> listBackups() {
    final entries = <BackupEntry>[];

    for (var i = 1; i <= AppPaths.rollingBackupCount; i += 1) {
      final file = paths.rollingBackup(i);
      if (!file.existsSync()) continue;
      final modifiedAt = file.lastModifiedSync().millisecondsSinceEpoch;
      final count = _recordCountOf(file);
      entries.add(BackupEntry(
        path: file.path,
        label: '上一份 · ${_clockLabel(modifiedAt)}${_countSuffix(count)}',
        kind: BackupKind.rolling,
        sizeBytes: file.lengthSync(),
        modifiedAt: modifiedAt,
        recordCount: count,
      ));
    }
    for (final file in _dailyBackups()) {
      final name = file.uri.pathSegments.last;
      final date = name
          .substring(AppPaths.dailyPrefix.length)
          .replaceAll('.json', '');
      final modifiedAt = file.lastModifiedSync().millisecondsSinceEpoch;
      final count = _recordCountOf(file);
      entries.add(BackupEntry(
        path: file.path,
        label: '日快照 $date${_countSuffix(count)}',
        kind: BackupKind.daily,
        sizeBytes: file.lengthSync(),
        modifiedAt: modifiedAt,
        recordCount: count,
      ));
    }
    return entries;
  }

  /// `09-26 11:57`（年份省略：滚动备份都是最近几天的，日快照的日期在标签里）。
  static String _clockLabel(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String _countSuffix(int? count) => count == null ? '' : ' · $count 条';

  /// 备份文件里 `items` 的总条数（含墓碑 / 归档，就是文件里实实在在的条数）。
  ///
  /// 解析不了返回 `null`：**这一份仍然要列出来、仍然能恢复**，只是少一条信息 ——
  /// 备份可能来自旧版本，因为"数不出条数"就把它藏起来是最糟的选择。
  int? _recordCountOf(File file) {
    try {
      final text = file.readAsStringSync(encoding: utf8);
      // 先确认是合法 JSON：坏文件会被 StoreFile.parse 静默读成空数据，
      // 那样标签会写成"0 条"，比不写还误导
      Canonical.decode(text);
      final parsed = StoreFile.parse(text, DecodeIssues());
      var total = 0;
      for (final name in DocName.values) {
        total += parsed.documentOf(name).items.length;
      }
      return total;
    } catch (_) {
      return null;
    }
  }

  /// 从备份恢复：先把**当前**主文件轮转走（避免恢复动作本身造成不可逆），再替换。
  ///
  /// 走的是**强制**那条路（`forceRotate: true`）：用户点的就是"把现在这份换掉"，
  /// 万一刚轮转过就不留，恢复动作本身就成了不可逆的 —— 这正是 force 存在的理由。
  /// 写回时把 `savedAt` 记成此刻，与"损坏后自动写回"那条路同一个口径。
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
    save(parsed, nowMillis: nowMillis, forceRotate: true);
    return parsed;
  }

  /// 删掉某一份备份。
  ///
  /// 两条安全线，都是刻意的：
  ///   · **只认自己列的备份**——路径必须出现在 [listBackups] 里。这样即便有人把
  ///     别处传来的路径塞进来，也删不到主文件、偏好文件或背景图；
  ///   · **不允许删到一份不剩**——没有云端时本地备份是唯一的安全网，
  ///     "把备份清空"应该是不可能的操作。返回被拒绝的原因，让界面能如实说明。
  ///
  /// 返回 `null` 表示删掉了；否则返回拒绝原因。
  String? deleteBackup(String backupPath) {
    final entries = listBackups();
    final target = entries.where((e) => e.path == backupPath).firstOrNull;
    if (target == null) {
      return '这不是一份可删除的备份';
    }
    if (entries.length <= 1) {
      return '至少保留一份备份 —— 没有云端时它是唯一的安全网';
    }
    final file = File(backupPath);
    if (file.existsSync()) file.deleteSync();
    return null;
  }

  // ---------------------------------------------------------------- 实现计划的历史正文

  /// 「实现计划」历史正文的文件名。
  ///
  /// 它**不是数据**：不进主数据文件、不进导出、不进备份轮转，也没有 `schemaVersion`
  /// —— 只是一段"AI 覆盖正文之前那一版"的临时留档。所以它连 `AppPaths` 都不进，
  /// 省得被 `managedFiles`（`.tmp` 清理）和别人的路径清单当成数据文件看待。
  static const String implementationHistoryFileName = 'implementation_history.json';

  File get _implementationHistoryFile => File(
        '${paths.directory.path}${Platform.pathSeparator}'
        '$implementationHistoryFileName',
      );

  /// 留一份某项目「实现计划」的旧正文，供"退回上一版"。
  ///
  /// 失败**只当没存上**（读回来是 null，界面就不出现"退回上一版"）：
  /// 这是事后反悔用的护栏，不该因为它写不进去，把用户本来就要做的那次写入挡掉。
  void saveImplementationSnapshot(String projectId, String text) {
    final history = _readImplementationHistory();
    history[projectId] = text;
    try {
      paths.ensureDirectories();
      AtomicFile(_implementationHistoryFile).writeText(Canonical.documentText(history));
    } catch (_) {
      // 见上：护栏失败不阻断主流程
    }
  }

  /// 读回某项目的历史正文；没有（或读不出来、或存的是空串）返回 `null`。
  String? readImplementationSnapshot(String projectId) {
    final text = _readImplementationHistory()[projectId];
    return text == null || text.trim().isEmpty ? null : text;
  }

  /// 销掉某项目的历史正文（退回之后调用：**一份历史只值一次反悔**）。
  void clearImplementationSnapshot(String projectId) {
    final history = _readImplementationHistory();
    if (!history.containsKey(projectId)) return;
    history.remove(projectId);
    try {
      AtomicFile(_implementationHistoryFile).writeText(Canonical.documentText(history));
    } catch (_) {
      // 删不掉也不影响：下次写入会整份覆盖
    }
  }

  /// 读整份历史存档；文件不在 / 坏了都当"没有历史"。
  ///
  /// 坏了不报错是有意的：它只是一次反悔用的护栏，读不出来最多是少一个按钮，
  /// 绝不该在启动或保存路径上抛异常。
  Map<String, String> _readImplementationHistory() {
    final file = _implementationHistoryFile;
    if (!file.existsSync()) return <String, String>{};
    try {
      final decoded = Canonical.decode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return <String, String>{};
      final out = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is String) out[key] = value;
      }
      return out;
    } catch (_) {
      return <String, String>{};
    }
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

  /// 写一份**交接说明**（Markdown），返回它。
  ///
  /// 与 `guideline-*.json.gz` 的整库导出刻意分开：
  ///   · 文件名前缀是 `handoff-`，所以**不会被 `_pruneExports` 轮转掉**
  ///     —— 交接说明是用户特意生成的，删掉就得重新生成，成本比数据备份高；
  ///     所以它只积累、不自动清理，用户自己清理即可（文件很小，是纯文本）。
  ///   · 内容也只包含**用户预览过的那一个项目**，不是整库。
  File writeHandoffExport(int nowMillis, String markdown, {String? projectTitle}) {
    final dir = ensureExportsDir();
    final file = File(
      '${dir.path}${Platform.pathSeparator}${_handoffName(nowMillis, projectTitle)}',
    );
    AtomicFile(file).writeText(markdown);
    return file;
  }

  /// `handoff-<项目名>-YYYYMMDD-HHmmss.md`；项目名里的路径分隔符与空白会被收掉。
  String _handoffName(int millis, String? projectTitle) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${d.year}${two(d.month)}${two(d.day)}';
    final time = '${two(d.hour)}${two(d.minute)}${two(d.second)}';

    var slug = (projectTitle ?? '').trim();
    // 只留安全字符：文件名里出现 / \ 或控制字符会让写入直接失败
    slug = slug.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '-');
    slug = slug.replaceAll(RegExp(r'-+'), '-');
    if (slug.length > 30) slug = slug.substring(0, 30);
    slug = slug.replaceAll(RegExp(r'^-|-$'), '');
    final middle = slug.isEmpty ? '' : '$slug-';
    return 'handoff-$middle$date-$time.md';
  }

  /// `guideline-YYYYMMDD-HHmmss.json.gz`
  String _exportName(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${d.year}${two(d.month)}${two(d.day)}';
    final time = '${two(d.hour)}${two(d.minute)}${two(d.second)}';
    return 'guideline-$date-$time.json.gz';
  }

  // ---------------------------------------------------------------- 背景图

  /// 保存背景图（拷进应用私有目录，走原子替换）。
  File saveBackgroundImage(List<int> bytes) {
    final dir = paths.backgroundDir;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    AtomicFile(paths.backgroundImageFile).writeBytes(bytes);
    return paths.backgroundImageFile;
  }

  /// 读背景图字节；没有或读不出来返回 `null`（背景坏了不该影响启动）。
  Uint8List? readBackgroundImage() {
    final file = paths.backgroundImageFile;
    if (!file.existsSync()) return null;
    try {
      return file.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  void deleteBackgroundImage() {
    final file = paths.backgroundImageFile;
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 删不掉也无所谓：偏好里已经不再引用它了
    }
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
    this.recordCount,
  });

  final String path;

  /// 展示用标签：`上一份 · 09-26 11:57 · 42 条` / `日快照 20260926 · 42 条`
  final String label;

  final BackupKind kind;
  final int sizeBytes;
  final int modifiedAt;

  /// 这份备份里 `items` 的总条数；**解析不了给 `null`**（不猜、也不写成 0）
  final int? recordCount;
}
