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
import 'github_sync.dart';
import 'ui_prefs.dart';

/// 启动加载报告：把"读到了什么"与"哪里有问题"一起交给上层。
class LoadReport {
  const LoadReport({
    required this.store,
    required this.prefs,
    required this.issues,
    required this.quarantinedPaths,
    this.recoveredFromBackup,
    this.storeLockedByNewerSchema = false,
  });

  final StoreFile store;
  final UiPrefs prefs;
  final DecodeIssues issues;

  /// 被隔离保留的损坏文件路径（**绝不静默重建空数据**）
  final List<String> quarantinedPaths;

  /// 若主文件损坏、自动用备份恢复，这里是所用备份的路径
  final String? recoveredFromBackup;

  /// 主文件的 `schemaVersion` **高于本应用支持的版本**。
  ///
  /// 这种文件只是"看不懂"，**不是损坏**：绝不能隔离它、更不能拿空数据把它换掉。
  /// 出现这个标记时 [AppStorage.save] 会拒绝写盘，直到用户装上支持的版本。
  final bool storeLockedByNewerSchema;

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
    var lockedByNewerSchema = false;

    final file = paths.storeFile;
    if (!file.existsSync()) {
      // 主文件**不在**，并不等于「全新安装」。
      // 上次有可能正好死在「删旧文件 → 改名」那一步（或文件被外部清理掉了）。
      // 只要还有备份，就必须恢复 + 明确告警 —— 全新安装没有任何备份，走不到这里。
      final recovery = _loadNewestBackup(issues);
      if (recovery != null) {
        store = recovery.store;
        recoveredFrom = recovery.path;
        issues.error('主数据文件不存在，已从备份恢复：${recovery.path}');
        _writeBackRecovered(store, stamp, issues);
      }
    } else {
      // 读取本身也可能失败：**非法 UTF-8**（掉电 / 半截写入的典型产物）、I/O 错误、
      // 目标被同名目录占位。旧实现里这里是裸调，异常会一路冒到 main，用户看到的是
      // 启动崩溃 —— 连设置页都进不去，更别说从备份恢复。读不出来也只是"损坏"的一种。
      String? text;
      try {
        text = file.readAsStringSync(encoding: utf8);
      } catch (error) {
        issues.error('主数据文件读取失败：$error');
      }

      final parsed = text == null
          ? (store: null, lockedByNewerSchema: false)
          : _tryParse(text, issues);

      if (parsed.lockedByNewerSchema) {
        // **不是损坏，是"看不懂"**：这份文件可能来自更新版本的 App（或双端混用）。
        // 隔离它、或用空数据盖掉它，都是不可逆的数据丢失 —— 用户的真数据就在里面。
        // 所以这里什么都不动：主文件留在原地，只把情况告诉用户。
        issues.error(
          '主数据文件由更新版本的 App 写入，已保持原样未改动。'
          '请升级 App 后再打开，否则本次会显示为空数据。',
        );
        lockedByNewerSchema = true;
        _lockedByNewerSchema = true;
      } else if (parsed.store != null) {
        store = parsed.store!;
      } else {
        // 主文件读不出来 / 读不了 → 隔离现场，然后尝试最近的备份
        issues.error('主数据文件无法解析，已隔离保留现场');
        quarantined.add(AtomicFile(file).quarantine(stamp));
        _pruneQuarantine();
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
      storeLockedByNewerSchema: lockedByNewerSchema,
    );
  }

  /// 主文件是"更新版本写的"吗？（本次 [`load`] 里发现，或 [`save`] 时在磁盘上发现）
  ///
  /// 一旦为真就**不再写盘**：那种文件属于更高版本的 App，这边一写就等于把
  /// 用户在新版里的数据换成一份旧形态的空壳。
  bool _lockedByNewerSchema = false;

  /// 磁盘上的主文件是不是"更新版本写的"。**[save] 的最后一道防线。**
  ///
  /// 为什么不能只靠 [load] 记的标记：用户可能在旧版里打开（看到告警）、把进程留在后台，
  /// 期间用新版写了数据，回到旧版界面继续编辑 —— 这时内存里的标记是过期的，
  /// 而盘上的文件已经变新了。所以每次写盘之前现读一眼。
  ///
  /// 只在文件开头找 `schemaVersion`（它是第一个键），不做完整解析。
  bool _diskLockedByNewerSchema() {
    try {
      final file = paths.storeFile;
      if (!file.existsSync()) return false;
      final raf = file.openSync();
      try {
        final head = utf8.decode(
          raf.readSync(1024),
          allowMalformed: true,
        );
        final match = RegExp(r'"schemaVersion"\s*:\s*(\d+)').firstMatch(head);
        if (match == null) return false;
        final version = int.tryParse(match.group(1)!);
        return version != null && version > StoreFile.currentSchemaVersion;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      // 读不出来时不拦：那属于"损坏"那条路，交给 load 的隔离与恢复处理
      return false;
    }
  }

  /// 尝试解析；**区分"解析不了"与"版本高于本应用"**。
  ///
  /// 返回值里 `store != null` 才算成功。这个区分是 P0-1 的核心：
  /// [StoreFile.parse] 对"版本过高"只记一条 error 并返回空 store，如果把它当成功，
  /// 上层就会拿着一份空库继续跑，第一次保存就把用户的真数据覆盖掉。
  ({StoreFile? store, bool lockedByNewerSchema}) _tryParse(String text, DecodeIssues issues) {
    try {
      Canonical.decode(text);
    } catch (_) {
      return (store: null, lockedByNewerSchema: false);
    }
    final parsed = StoreFile.parse(text, issues);
    return (
      store: parsed,
      lockedByNewerSchema: _isNewerSchema(issues),
    );
  }

  /// [StoreFile.parse] 的"版本过高"分支留下的那条 error。
  ///
  /// 按文案匹配不理想，但 `StoreFile.parse` 在那一支里只返回空 store、没有别的出口；
  /// 这条文案同时也是给用户看的，改动它会被 `app_storage_test.dart` 的 P0-1 用例拦下。
  bool _isNewerSchema(DecodeIssues issues) =>
      issues.errors.any((e) => e.contains('高于本应用支持的'));

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

  ({StoreFile store, String path})? _loadNewestBackup(DecodeIssues issues) {
    final candidates = <File>[
      for (var i = 1; i <= AppPaths.rollingBackupCount; i += 1) paths.rollingBackup(i),
      ..._dailyBackups(),
    ].where((f) => f.existsSync()).toList();

    // 越新的排在前面：滚动备份 1 最新；日快照按修改时间倒序（同 [_newestFirst]）
    candidates.sort((a, b) {
      final aRolling = _rollingIndex(a);
      final bRolling = _rollingIndex(b);
      if (aRolling != null && bRolling != null) return aRolling.compareTo(bRolling);
      if (aRolling != null) return -1;
      if (bRolling != null) return 1;
      return _newestFirst(a, b);
    });

    for (final candidate in candidates) {
      try {
        final text = candidate.readAsStringSync(encoding: utf8);
        final issues = DecodeIssues();
        final parsed = _tryParse(text, issues);
        // **不能只判 `documents.isNotEmpty`**：`StoreFile.parse` 对四个集合永远赋值，
        // 那个条件恒为真 —— 于是任何"能被 parse 收下的文本"（`[1,2,3]`、版本过高的、
        // 记录全坏的）都会被当成恢复来源，用空数据把主文件换掉，还向用户报"已从备份恢复"。
        // 真正的判据是"它里面有记录"。
        if (parsed.store != null && _hasAnyRecord(parsed.store!)) {
          return (store: parsed.store!, path: candidate.path);
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// 这份 store 里**真的有记录**吗。
  ///
  /// 用来区分"一份可用的备份"与"一份解析得动、但内容是空壳的文件"——
  /// 后者在 [StoreFile.parse] 眼里同样"成功"，拿它恢复等于用空数据覆盖真数据。
  static bool _hasAnyRecord(StoreFile store) {
    for (final name in DocName.values) {
      if (store.documentOf(name).items.isNotEmpty) return true;
    }
    return false;
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
    files.sort(_newestFirst);
    return files;
  }

  /// 按**文件修改时间**倒序（新的在前）。
  ///
  /// 刻意不按文件名字符串排（P1-10）：日快照的名字是"生成那一刻的设备日期"，
  /// 设备时钟被往后改（或跨时区）就会产出一个未来日期的文件名，按名字排会把它
  /// 当成"最新"而挤掉真正最近的那几份。mtime 是文件系统给的，不做这种假设。
  static int _newestFirst(File a, File b) {
    final at = a.lastModifiedSync().millisecondsSinceEpoch;
    final bt = b.lastModifiedSync().millisecondsSinceEpoch;
    if (at != bt) return bt.compareTo(at);
    // 同一毫秒（罕见）时用名字兜底，保证排序稳定
    return b.path.compareTo(a.path);
  }

  // ---------------------------------------------------------------- 写

  /// 不在编辑会话时的轮转**最小间隔**：5 分钟。
  ///
  /// 它是"节流"不是"定时"：只要距上次轮转够久，下一笔保存就会留下新的备份。
  /// 取值理由：手机上的连续编辑（改个名、勾一条、补一句）通常集中在几分钟内，
  /// 这段时间里留一份就够回退；而 5 分钟又短到"随手改改"也不至于整天不落后备。
  static const int rotateMinIntervalMillis = 5 * 60 * 1000;

  /// 会话"不活动"多久就视为已结束（P1-6）。
  ///
  /// 比 [rotateMinIntervalMillis] 长一档：正常的连续编辑不会跨这么久，
  /// 而卡住的会话必须有个上限 —— 否则备份会整个进程生命周期停更。
  static const int editSessionIdleLimitMillis = 30 * 60 * 1000;

  /// 是否正处在一段编辑会话里（进编辑页面 → 离开）。
  bool get inEditSession => _inEditSession;

  bool _inEditSession = false;

  /// 本会话是否已经轮转过 —— **一段会话只留一份备份**，即"进页面之前"的那份。
  bool _rotatedInSession = false;

  /// 上次轮转的时刻；非会话期间的节流以它为基准（`null` = 还没轮转过）。
  int? _lastRotateAt;

  /// 上次保存的时刻 —— 判断会话是否已经"不活动"用（P1-6）。
  int? _lastSaveAt;

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
    // 需求①的基线：这一趟是从盘上哪一版开始编辑的。
    _sessionStartRevision = _dataRevision;
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

    // **看不懂的文件不覆盖**（P0-1）：盘上的主文件若由更新版本的 App 写入，
    // 这一写就等于把用户在新版里的数据换成一份旧形态的空壳，而且不可恢复。
    // 本次 load 已经发现、或期间文件被新版改过，都在这里拦下。
    if (_lockedByNewerSchema || _diskLockedByNewerSchema()) {
      _lockedByNewerSchema = true;
      return;
    }

    final stamped = store.copyWith(savedAt: now);

    if (forceRotate) {
      _rotateNow(now);
    } else if (_inEditSession && !_editSessionExpired(now)) {
      if (!_rotatedInSession) _rotateNow(now);
    } else if (_rotateDue(now)) {
      // 会话卡住时也走到这里：备份不会因为一根没配对的标志永远停更（P1-6）
      _rotateNow(now);
    }

    AtomicFile(paths.storeFile).writeText(stamped.toCanonicalText());
    // 盘上的数据变了一版 —— 自动同步靠这个数判断"这次编辑真的改过东西"（需求①）。
    _dataRevision += 1;
    _lastSaveAt = now;
  }

  /// 与"备份文件集合"有关的修订号：轮转、删备份、写回恢复结果时 +1。
  ///
  /// 给上层做缓存用（Q-4）：[listBackups] 要解析每一份备份才能报出条数，
  /// 而界面在**每次重建**时都会读它 —— 不加缓存的话，一条通知就重解析十几份文件。
  /// 上层记住"这份缓存对应哪个修订号"，只有变了才重新算。
  int get backupsRevision => _backupsRevision;
  int _backupsRevision = 0;

  /// 数据修订号：**主数据文件真的落盘一版**就 +1（需求①的触发依据）。
  ///
  /// 与 [backupsRevision] 不是一回事：那个数"备份文件的集合"变没变，这个数
  /// "盘上的活数据改过几版" —— 自动同步靠它回答"这一段编辑会话里到底改没改过东西"。
  /// 被更新版本的 App 锁住而没写盘的那一次**不算**：盘上什么都没变。
  int get dataRevision => _dataRevision;
  int _dataRevision = 0;

  /// 本段编辑会话开始那一刻的修订号（[beginEditSession] 取的快照）。
  int _sessionStartRevision = 0;

  /// 这一段编辑会话里有没有真的写过盘。
  ///
  /// 上层在 `endEditSession()` **之后**才问它，所以 `endEditSession` 刻意不重置基线
  /// （一重置就永远回答"没改过"）。下一次 [beginEditSession] 会重新取快照。
  bool get editedSinceSessionStart => _dataRevision != _sessionStartRevision;

  /// 非会话期间该不该轮转：从没轮转过，或距上次已超过最小间隔。
  ///
  /// **会话保护会过期**（P1-6）：`_inEditSession` 是一根全局标志（`begin` / `end`
  /// 必须严格配对），一旦 predict-back 手势取消、路由被非对称移除之类的情况让它卡在
  /// "打开"状态，`_rotatedInSession` 早在第一笔写入时就被置真 —— 此后**整个进程生命周期
  /// 都不会再轮转备份**，而 App 切后台再回来是不重启进程的，这个状态能持续好几天。
  /// 所以超过 [editSessionIdleLimitMillis] 没有任何保存时，视为会话已结束，
  /// 让节流路径接管，备份不至于永远停更。
  bool _rotateDue(int now) {
    final last = _lastRotateAt;
    if (last == null) return true;
    // 取绝对值：设备时钟被往回改（或调用方给了更早的时间戳）时，
    // 不该把轮转永久锁死 —— 那是"备份再也不更新"，比多留一份危险得多。
    return (now - last).abs() >= rotateMinIntervalMillis;
  }

  /// 会话是否已经"不活动"到不该再拦住轮转。
  bool _editSessionExpired(int now) {
    final last = _lastSaveAt;
    if (last == null) return false;
    return (now - last).abs() >= editSessionIdleLimitMillis;
  }

  /// 轮转一次并记账（会话内 / 非会话 / 强制三条路都收敛到这里）。
  ///
  /// **只有真的写出至少一份备份才记"已轮转"**（P1-3）：旧实现无条件记账，
  /// 于是磁盘满 / 权限异常时会出现"主文件在写、一份备份都没有，而且本会话不再重试"，
  /// 界面上「立即备份一份」还会报成功 —— 用户以为有存档，其实一份都没有。
  void _rotateNow(int now) {
    if (!paths.storeFile.existsSync()) {
      // 没有"上一份"可轮转（刚装、或主文件被外部删了）：这不是失败，只是没事可做。
      // 记账照旧 —— 否则这一段操作里的每一笔写入都会白跑一次轮转。
      _lastRotateAt = now;
      _rotatedInSession = true;
      return;
    }
    final wrote = _rotateBackups(now);
    if (!wrote) {
      // 有东西可轮转却一份都没写出来（磁盘满 / 权限）：**不记账**，
      // 让下一次保存继续重试，而不是整个会话都不再留备份。
      return;
    }
    _lastRotateAt = now;
    _rotatedInSession = true;
    _backupsRevision += 1; // 备份集合变了，上层缓存作废（Q-4）
  }

  void savePrefs(UiPrefs prefs) {
    paths.ensureDirectories();
    AtomicFile(paths.prefsFile).writeText(prefs.toCanonicalText());
  }

  /// 滚动备份 + 日快照（**纯机械部分**：该不该轮转由调用方决定，见 [save]）。
  ///
  /// 返回"这一轮有没有真的写出一份备份"，由 [_rotateNow] 决定要不要记账。
  bool _rotateBackups(int now) {
    final store = paths.storeFile;
    if (!store.existsSync()) return false;

    var wroteAny = false;

    // 日快照：今天还没有快照时先留一份（在轮转之前，保证是"今天开始时的状态"）
    final today = _yyyymmdd(now);
    final todayFile = paths.dailyBackup(today);
    if (!todayFile.existsSync()) {
      if (_copyFile(store, todayFile)) wroteAny = true;
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
    if (_copyFile(store, paths.rollingBackup(1))) wroteAny = true;
    return wroteAny;
  }

  /// 备份移位：优先改名（O(1)），不行再退回复制。
  ///
  /// 备份永远不该阻断主流程，所以两条路都失败也只是这一次少一份备份 ——
  /// 但要**如实告诉调用方**（返回值），否则"这份操作有存档"会变成一句空话。
  bool _shiftFile(File from, File to) {
    try {
      if (to.existsSync()) to.deleteSync();
      from.renameSync(to.path);
      return true;
    } catch (_) {
      return _copyFile(from, to);
    }
  }

  /// 隔离区只留最近几份（P1-7）：它是求救通道，但也不能无限堆积 ——
  /// 用户在设置页里看不到这些文件，只加不清就成了无声的空间占用。
  void _pruneQuarantine() {
    final files = AtomicFile.quarantineFilesIn(paths.directory);
    for (var i = AppPaths.quarantineKeepCount; i < files.length; i += 1) {
      try {
        files[i].deleteSync();
      } catch (_) {
        // 清理失败不影响正确性
      }
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

  /// 复制一份文件当备份。
  ///
  /// 用文件系统级拷贝（`File.copySync`）而不是"读成字节数组再写"：
  /// 后者每次轮转都要把整份数据读进 Dart 堆，数据到几 MB 时在低端机上会 OOM，
  /// 而 OOM 是 `Error` 不是 `FileSystemException`，会绕过上层 `run()` 的兜底（P1-9）。
  ///
  /// 返回是否真的写成功 —— 让调用方（[_rotateNow] / [snapshotBackupNow]）
  /// 能诚实回答"这次到底有没有留下存档"。
  bool _copyFile(File from, File to) {
    try {
      from.copySync(to.path);
      return true;
    } catch (_) {
      // 备份失败不能阻断主流程（主文件仍会被原子写入）
      return false;
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
  /// 滚动备份的写法是连成一串的 `备份0930-21:49-123条`（用户口径）。
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
        label: '备份${_clockLabel(modifiedAt)}${_countSuffix(count)}',
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
        label: '日快照 $date${_dailyCountSuffix(count)}',
        kind: BackupKind.daily,
        sizeBytes: file.lengthSync(),
        modifiedAt: modifiedAt,
        recordCount: count,
      ));
    }
    return entries;
  }

  /// `0930-21:49`（年份省略：滚动备份都是最近几天的，日快照的日期在标签里）。
  static String _clockLabel(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.month)}${two(d.day)}-${two(d.hour)}:${two(d.minute)}';
  }

  /// 条数后缀：`-42条` / `-无法解析`（日期与条数之间不留空格，连成一串读）。
  static String _countSuffix(int? count) =>
      count == null ? '-无法解析' : '-$count条';

  /// 日快照那一侧的条数后缀：**保持旧写法**（用户口径：日快照不动）。
  static String _dailyCountSuffix(int? count) =>
      count == null ? ' · 无法解析' : ' · $count 条';

  /// 备份文件里 `items` 的总条数（含墓碑 / 归档，就是文件里实实在在的条数）。
  ///
  /// **一份"0 条"的备份不算可用备份，返回 `null`**（P1-8）：
  /// 早先这里对 `[1,2,3]`、`schemaVersion` 过高、记录全坏这类文件都返回 `0`，
  /// 于是标签写成"日快照 20260906 · 0 条"——看起来像一份"空但合法"的备份，
  /// 用户点恢复就会把主文件换成空数据。注释本来就写着"不写成 0，那样比不写还误导"，
  /// 但实现没做到；现在做到了，并与 [_hasAnyRecord] / [_loadNewestBackup] 同一套判据。
  static int? _recordCountOf(File file) {
    try {
      final text = file.readAsStringSync(encoding: utf8);
      final parsed = StoreFile.parse(text, DecodeIssues());
      var total = 0;
      for (final name in DocName.values) {
        total += parsed.documentOf(name).items.length;
      }
      return total == 0 ? null : total;
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
    final parsed = _tryParse(backup.readAsStringSync(encoding: utf8), issues);
    // **不能判 `documents.isEmpty`**：`StoreFile.parse` 对四个集合永远赋值，条件恒假，
    // 于是"恢复一份空备份"不会被拦下，用户点一下就把主文件换成空数据（P1-8）。
    if (parsed.store == null || !_hasAnyRecord(parsed.store!)) {
      throw StateError('这份备份里没有可恢复的记录：$backupPath');
    }
    save(parsed.store!, nowMillis: nowMillis, forceRotate: true);
    return parsed.store!;
  }

  /// **只读**一份备份的内容，用于"恢复之前先看看差在哪"（不动主文件、不写任何东西）。
  ///
  /// 判据与 [restoreFromBackup] 一字不差：路径必须是 [listBackups] 列得出的，
  /// 而且那份备份至少得有一条记录。放水的话，差异面板会替一份"0 条"的假备份
  /// 摆出一屏"把现有数据全删了"的红行 —— 比不显示更吓人。
  ///
  /// 返回 `null` = 读不了 / 不可用，界面照实说，不要编造一份空版本。
  StoreFile? readBackupStore(String backupPath) {
    final known = listBackups().any((entry) => entry.path == backupPath);
    if (!known) return null;
    final file = File(backupPath);
    if (!file.existsSync()) return null;
    try {
      final parsed = _tryParse(file.readAsStringSync(encoding: utf8), DecodeIssues());
      final store = parsed.store;
      if (store == null || !_hasAnyRecord(store)) return null;
      return store;
    } catch (_) {
      return null;
    }
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
      return '至少要保留一份备份，没有云端时它是唯一的安全网';
    }
    final file = File(backupPath);
    if (file.existsSync()) file.deleteSync();
    _backupsRevision += 1; // 备份集合变了，上层缓存作废（Q-4）
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

  // -------------------------------------------------- 「重置」之前的留档（一次反悔）

  /// 「重置」之前那一版的留档文件名。
  ///
  /// 与 [implementationHistoryFileName] 同一档：**不是数据**，不进主数据文件、
  /// 不进导出、不进备份轮转，也没有 `schemaVersion`。区别只在内容 ——
  /// 那份存"某项目旧正文一个字符串"，这份存"重置涉及的每个项目的
  /// `purpose` + `implementation` + 清单条目"，因为重置一次会动好几个项目。
  static const String resetSnapshotFileName = 'reset_snapshot.json';

  File get _resetSnapshotFile => File(
        '${paths.directory.path}${Platform.pathSeparator}$resetSnapshotFileName',
      );

  /// 留一份"重置之前"的快照，供"退回上一版"。
  ///
  /// 走的是**整份覆盖**：一份留档只值一次反悔（与历史正文同一条口径），
  /// 所以第二次重置会把上一次的留档顶掉，不留多份。
  /// 写不进去**只当没存上** —— 它是事后反悔的护栏，不该反过来挡住用户要做的事。
  void saveResetSnapshot(Map<String, Map<String, dynamic>> snapshot) {
    try {
      paths.ensureDirectories();
      AtomicFile(_resetSnapshotFile).writeText(Canonical.documentText(snapshot));
    } catch (_) {
      // 见上：护栏失败不阻断主流程
    }
  }

  /// 读回"重置之前"的留档；没有（或读不出来、或空的）返回 `null`。
  ///
  /// 坏了不报错：读不出来最多是少一个"退回上一版"，绝不该在启动路径上抛异常。
  Map<String, Map<String, dynamic>>? readResetSnapshot() {
    final file = _resetSnapshotFile;
    if (!file.existsSync()) return null;
    try {
      final decoded = Canonical.decode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return null;
      final out = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is Map) {
          out[key] = value is Map<String, dynamic> ? value : value.cast<String, dynamic>();
        }
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// 销掉"重置之前"的留档（退回之后调用：**一份留档只值一次反悔**）。
  void clearResetSnapshot() {
    final file = _resetSnapshotFile;
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } catch (_) {
      // 删不掉也不影响：下次重置会整份覆盖
    }
  }

  // -------------------------------------------------- GitHub 备份同步的记账

  /// 「上次与 GitHub 同步到哪」的记账文件名。
  ///
  /// 与 [implementationHistoryFileName] / [resetSnapshotFileName] **同一档**：
  /// 不是数据，不进主数据文件、不进导出、不进备份轮转，也没有 `schemaVersion`。
  /// 区别在丢了会怎样 —— 前两份丢了是少一次"退回上一版"，这份丢了最坏是
  /// 下一次同步判定退化成"两边都比对不出来"，让用户手动选一次，
  /// **任何一条真实记录都不受影响**。
  static const String githubSyncRecordFileName = 'github_sync.json';

  File get _githubSyncFile => File(
        '${paths.directory.path}${Platform.pathSeparator}$githubSyncRecordFileName',
      );

  /// 读回同步记账；没有 / 读不出 / 坏了一律返回 `null`（当"没同步过"）。
  ///
  /// 坏了不报错是有意的：它只决定"能不能自动判断该推还是该拉"，
  /// 不该在启动或推送路径上抛异常。解析交给 `SyncRecord.parse` 自己做
  /// 形状校验（缺键、类型不对都当没有）。
  SyncRecord? readSyncRecord() {
    final file = _githubSyncFile;
    if (!file.existsSync()) return null;
    try {
      return SyncRecord.parse(file.readAsStringSync(encoding: utf8));
    } catch (_) {
      return null;
    }
  }

  /// 记一次成功的同步。
  ///
  /// 写不进去**只当没记上**：文件已经推上去了（或已经拉下来了），
  /// 真实结果不因为这一份记账写失败而改变 —— 与"护栏失败不阻断主流程"同一口径。
  void writeSyncRecord(SyncRecord record) {
    try {
      paths.ensureDirectories();
      AtomicFile(_githubSyncFile).writeText(record.toCanonicalText());
    } catch (_) {
      // 见上
    }
  }

  /// 清掉记账（例如用户换了仓库 / 分支 / 路径：旧记账对新落点没有意义）。
  void clearSyncRecord() {
    final file = _githubSyncFile;
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } catch (_) {
      // 删不掉也不影响：下次同步会整份覆盖
    }
  }

  /// 「GitHub 未连接」那句警告最近是哪一天弹过的（需求⑤ / Q-6：**当天只弹一次**）。
  ///
  /// 与同步记账**共用一份文件**，但只认 `offlineWarnedOn` 这一个键：
  /// 它和记账一样"丢了也不影响任何一条真实记录"，最坏是当天多弹一次警告。
  /// 存日期字符串而不是时间戳，是因为口径是"当天"而不是"24 小时以内" ——
  /// 跨过零点之后第一次开机，就该重新提醒一次。
  String readOfflineWarnedOn() {
    final file = _githubSyncFile;
    if (!file.existsSync()) return '';
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return '';
      final day = decoded['offlineWarnedOn'];
      return day is String ? day : '';
    } catch (_) {
      return '';
    }
  }

  /// 记下"[day] 这一天已经提醒过连不上了"。
  ///
  /// 写的是**整份 JSON**，所以先把盘上现有的键读回来再补一个 —— 不能拿一个
  /// 空的 `SyncRecord` 去写：伪造出来的 `syncedAt` 会让冲突判定拿着错基线，
  /// 把"只有一边改过"判成"两边都改过"。
  void writeOfflineWarnedOn(String day) {
    if (day.isEmpty) return;
    try {
      paths.ensureDirectories();
      var current = <String, dynamic>{};
      final file = _githubSyncFile;
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
        if (decoded is Map) current = Map<String, dynamic>.from(decoded);
      }
      current['offlineWarnedOn'] = day;
      AtomicFile(_githubSyncFile).writeText(Canonical.documentText(current));
    } catch (_) {
      // 与 writeSyncRecord 同一口径：写不进去只当没记上。
    }
  }

  /// 主数据文件里那句 `savedAt`：**本地数据最后一次落盘的时刻**。
  ///
  /// 冲突判定要拿它跟远程那份的 `exportedAt` 比。这里刻意**不用
  /// `Workspace.buildStoreFile().savedAt`** —— 那个是每次调用现取的 `now()`，
  /// 于是本地永远显得"刚改过"，「两边都改过」这条判定就再也退不出来。
  ///
  /// 纯读：不改盘、不轮转备份、不隔离坏文件；读不出返回 `null`
  /// （当"说不清"，由调用方按"本地可能改过"处理，宁可多问一次）。
  int? readStoreSavedAt() {
    final file = paths.storeFile;
    if (!file.existsSync()) return null;
    try {
      final decoded = Canonical.decode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return null;
      final savedAt = decoded['savedAt'];
      return (savedAt is int && savedAt > 0) ? savedAt : null;
    } catch (_) {
      return null;
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

  /// 展示用标签：`备份0930-21:49-42条` / `日快照 20260926 · 42 条`
  final String label;

  final BackupKind kind;
  final int sizeBytes;
  final int modifiedAt;

  /// 这份备份里 `items` 的总条数；**解析不了给 `null`**（不猜、也不写成 0）
  final int? recordCount;
}
