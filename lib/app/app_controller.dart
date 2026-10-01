import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/ids.dart';
import '../core/json/store_file.dart';
import '../core/models/ai_config.dart';
import '../core/models/entity.dart';
import '../core/models/github_backup_config.dart';
import '../core/models/project.dart';
import '../core/store/app_paths.dart';
import '../core/store/app_storage.dart';
import '../core/store/export_codec.dart';
import '../core/store/github_sync.dart';
import '../core/store/store_diff.dart';
import '../features/workspace.dart';
import '../platform/ai_client.dart';
import '../platform/data_directory.dart';
import '../platform/data_transfer_platform.dart';
import '../platform/github_backup_client.dart';
import 'auto_sync_state.dart';

/// 分享动作的可注入钩子（真机走 [DataTransferPlatform.shareFile]）。
///
/// 留这个口子的原因很具体：`share_plus` 在纯 Dart 测试里没有实现，而
/// 「没分享出去就不算导出」这条语义**恰恰只有在"分享被取消"那条分支上才验得出来**。
typedef ShareFileHook = Future<bool> Function(
  String path, {
  required String text,
  required String subject,
});

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
    this.quarantinedPaths = const <String>[],
    this.recoveredFromBackupPath,
    AiTextGenerator? aiGenerator,
    AiCredentialStore? credentialStore,
    ShareFileHook? shareFile,
    GitHubBackupGateway? gitHubGateway,
    GitHubCredentialStore? gitHubCredentials,
  })  : startupWarnings = List<String>.unmodifiable(startupWarnings),
        ai = aiGenerator ?? const HttpAiTextGenerator(),
        credentials = credentialStore ?? const SecureAiCredentialStore(),
        shareFile = shareFile ?? _defaultShareFile,
        gitHub = gitHubGateway ?? HttpGitHubBackupGateway(),
        gitHubStore = gitHubCredentials ?? const SecureGitHubCredentialStore();

  /// 从磁盘装配（唯一入口）。
  static Future<AppController> bootstrap({
    Directory? dataDirectoryOverride,
    AiTextGenerator? aiGenerator,
    AiCredentialStore? credentialStore,
    ShareFileHook? shareFile,
    GitHubBackupGateway? gitHubGateway,
    GitHubCredentialStore? gitHubCredentials,
  }) async {
    final dir = await DataDirectory.resolve(override: dataDirectoryOverride);
    final storage = AppStorage(AppPaths(dir));
    final report = storage.load();
    final workspace = Workspace.fromLoad(storage, report);
    final controller = AppController(
      storage: storage,
      workspace: workspace,
      dataDirectory: dir,
      startupWarnings: buildWarnings(report),
      quarantinedPaths: report.quarantinedPaths,
      recoveredFromBackupPath: report.recoveredFromBackup,
      aiGenerator: aiGenerator,
      credentialStore: credentialStore,
      shareFile: shareFile,
      gitHubGateway: gitHubGateway,
      gitHubCredentials: gitHubCredentials,
    ).._loadBackgroundBytes();
    // 灵感箱空态那句轮换文案**每次启动重抽**（ADR-084）。落进偏好是为了
    // "同一次运行里不再变" —— 界面只读它，不自己抽。
    controller.rollEmptyBoxLine();
    // 有事故时**不动磁盘**：清理过期墓碑会写盘，而"载入过程中发现问题"这一刻
    // 最不该再往盘上写东西（P0-3）。数据没问题的正常路径照旧清理。
    if (!report.hasProblems && !report.storeLockedByNewerSchema) {
      controller._purgeExpiredTrash();
    }
    controller._remindExportAfterIncident(report);
    return controller;
  }

  static Future<bool> _defaultShareFile(
    String path, {
    required String text,
    required String subject,
  }) =>
      DataTransferPlatform.shareFile(path, text: text, subject: subject);

  /// 编辑会话的**路由观察者**：推开一个页面 = 一段编辑会话的开始，回到外壳 = 结束。
  ///
  /// 为什么用观察者而不是在每个编辑页里埋点：编辑面散在项目详情 / 事件详情 / 任务线 /
  /// 合并编辑器等多个页面（分属不同批次、不同文件），逐页埋点必然会漏；
  /// 而"进页面 → 离开"这件事对所有页面都是同一个形状，观察者是唯一不会漏的那一处。
  ///
  /// 只认 `PageRoute`：`showDialog` / 底部面板 / 弹出菜单走的是 `PopupRoute`，
  /// 它们不是"编辑页面"，不该打断或重置会话。
  ///
  /// 回到外壳这一下同时是**自动同步的触发点**（handoff #87c57e）：先落盘，再看要不要
  /// 自动上传 —— 两件事都在 [autoSyncAfterHome] 里，顺序也在那儿，别在这里拆开。
  late final NavigatorObserver editSessionObserver = _EditSessionObserver(
    onEnter: storage.beginEditSession,
    onLeave: () => unawaited(autoSyncAfterHome()),
  );

  /// 启动时清一次回收站（墓碑只留 `trashRetentionDays` 天）。
  ///
  /// 失败**不打断启动**：清理是"维护动作"，写盘失败时下次启动会再试一次，
  /// 比在启动路径上抛异常（用户看到白屏）合理得多。清理条数记在
  /// [lastTrashPurgedCount] 里，设置页 / 用例可以看。
  void _purgeExpiredTrash() {
    try {
      lastTrashPurgedCount = workspace.purgeExpiredTrash();
    } on FileSystemException {
      lastTrashPurgedCount = 0;
    }
  }

  /// 上次启动清理掉了几条过期墓碑（0 = 没清）。
  int lastTrashPurgedCount = 0;

  /// 本次启动被隔离保留的损坏文件（**完整路径**，界面只显示文件名）。
  final List<String> quarantinedPaths;

  /// 本次启动是用哪一份备份恢复的（`null` = 没发生恢复）。
  final String? recoveredFromBackupPath;

  /// 这次启动有没有发生过数据事故（损坏 / 隔离 / 自动恢复）。
  bool get hasDataIncident =>
      quarantinedPaths.isNotEmpty || recoveredFromBackupPath != null;

  /// 恢复来源的**文件名**（告警条上要说的就是"从哪一份恢复的"）。
  String? get recoveredFromBackupFileName => recoveredFromBackupPath == null
      ? null
      : _fileNameOf(recoveredFromBackupPath!);

  /// 隔离文件的**文件名**列表（完整路径太长，界面上给名字 + 目录）。
  List<String> get quarantinedFileNames =>
      <String>[for (final path in quarantinedPaths) _fileNameOf(path)];

  /// 告警条点开后逐条显示的明细。
  List<String> get dataIncidentLines {
    final lines = <String>[];
    final from = recoveredFromBackupFileName;
    if (from != null) lines.add('已从备份恢复：$from');
    for (final name in quarantinedFileNames) {
      lines.add('损坏的原文件已隔离保留：$name');
    }
    if (lines.isEmpty) {
      lines.add('主数据文件读入时发现异常，已按《数据契约》的容错口径降级处理');
    }
    return lines;
  }

  /// 数据事故之后**重新拉响导出提醒**。
  ///
  /// 没有云端时导出是数据离开这台手机的唯一通道；刚发生过损坏或自动恢复，
  /// 说明本地这一份已经不能全信 —— 这时界面上若还写着"上次导出很新，不用导"，
  /// 等于把最该导出的一次轻轻放过。做法是把 `lastExportedAt` 清回"从未导出"。
  void _remindExportAfterIncident(LoadReport report) {
    if (!report.hasProblems) return;
    workspace.updatePrefs(prefs.copyWith(lastExportedAt: null));
  }

  final AppStorage storage;

  /// 恢复备份后会整体替换（UI 每次重建都读 `ws`，因此替换是安全的）
  Workspace workspace;

  final Directory dataDirectory;

  final List<String> startupWarnings;

  /// AI 联网实现（默认走 HTTP；测试注入假实现）
  final AiTextGenerator ai;

  /// `apiKey` 的保管处（默认 `flutter_secure_storage`）
  final AiCredentialStore credentials;

  /// 把文件交给系统分享面板的动作（默认走平台通道；用例注入假实现）。
  final ShareFileHook shareFile;

  /// GitHub 备份同步的联网实现（默认走 Contents API；测试注入假实现）。
  final GitHubBackupGateway gitHub;

  /// GitHub Token 的保管处（与 AI 的 `apiKey` **分开存**，两者的权限量级不同）。
  final GitHubCredentialStore gitHubStore;

  Workspace get ws => workspace;

  UiPrefs get prefs => workspace.prefs;

  int get projectCount => workspace.liveProjects.length;

  /// 任务总数：**排除已归档** —— 「更多 → 全部任务」页头那个「共 N 条（含子任务）」
  /// 用的就是它，入口副标题与页内数字必须是同一个数（Q20）。
  ///
  /// ⚠️ **这个口径与 [projectCount] 不同，两者不要相加。**
  /// 2026-10-01 清掉两个零调用的 getter（`eventCount` / `inspirationCount`）时
  /// 顺手把这件事写清楚 —— 此前它们四个并排放在一起，看着像"一套计数"，
  /// 实际上：
  ///
  /// | 计数 | 口径 |
  /// |---|---|
  /// | [projectCount] | 未删除，**含已归档** |
  /// | [taskCount] | 未删除，**排除已归档**（与「全部任务」页头一致） |
  /// | `export_page.dart` 的 `_currentCounts` | 未删除，**含已归档** —— 导出是把盘上活记录备走，已归档也要备 |
  /// | [searchableCount] | 未归档（灵感还只算待处理的），能搜到的那批 |
  ///
  /// 两个已删的 getter 是**零调用点**的：生产代码里没有任何地方读过它们
  /// （只有上面那段注释提到），留着只会让人以为"这四个是一组的"。
  int get taskCount => workspace.liveTasks.where((t) => !t.archived).length;

  /// 归档区总数（Q20）。归档区现在是**三档**：已归档 / 已处理的灵感 / 回收站，
  /// 「更多」页入口副标题写的就是这三档的名字，所以这个数必须等于**点进去能看到的条数之和**。
  ///
  /// 为什么还要加 `inspirationsHiddenByArchivedProjects`：`ArchiveZone.totalCount`
  /// 数的是「已归档 + 已丢弃 + 已合并 + 回收站」四路，而「因所属项目归档而看不见」的那些
  /// 待处理灵感属于「已处理的灵感」那一档、却不在前面四路里 —— 不加它就少算一档。
  int get archiveCount =>
      workspace.archiveZone.totalCount + workspace.inspirationsHiddenByArchivedProjects;

  /// **已逾期**：口径与算法**只有一处** —— `Workspace.overdueTasks()`（Q19）。
  ///
  /// 外壳的逾期横幅、底部「更多」的角标、以及落点页面「接下来的任务」里
  /// 「已逾期」那一组，三处调的是同一个函数，报的自然是同一个数。
  int get overdueCount => workspace.overdueTasks().length;

  /// **能搜到的东西有几条**（Q20）——「更多」入口那个「N 条内容可搜」用的就是它。
  ///
  /// 以前这里自己加了一遍 `projectCount + taskCount + …` 之类的和：那几个 getter
  /// **口径各不相同**（见下），而搜索实际只搜未归档的（灵感还只搜待处理的），
  /// 于是那句话写着"（不含已归档）"、数字却是含归档算出来的。
  /// 现在入口与搜索页调的是 `Workspace.searchableContentCount` 同一个口径。
  int get searchableCount => workspace.searchableContentCount;

  /// 备份列表。**带缓存**（Q-4）：[AppStorage.listBackups] 要解析每一份备份才能报出条数，
  /// 而界面（「更多」页 + 备份页）在每次重建时都会读它 —— 一条通知就重解析十几份文件。
  /// 缓存用 `backupsRevision` 判新旧：轮转一次就换一茬，所以只在真的变了时才重算。
  List<BackupEntry> get backups {
    if (_backupsCacheRevision != storage.backupsRevision) {
      _backupsCache = storage.listBackups();
      _backupsCacheRevision = storage.backupsRevision;
    }
    return _backupsCache;
  }

  List<BackupEntry> _backupsCache = const <BackupEntry>[];
  int _backupsCacheRevision = -1;

  int? get lastExportedAt => workspace.lastExportedAt;

  /// **本机这一份的内容指纹**（7 位）—— GitHub 页点阵屏**下排**读它。
  ///
  /// 是**现算**的、不是记账里的旧值：下排要回答的是"我此刻这份是哪一版"，
  /// 拿上次同步时记下的旧指纹会让"本地又改过了"这件事在屏上完全看不出来。
  /// 上排放的是云端提交码（记账里的 `commitSha`），两者职责不同。
  String get localContentSha => workspace.localContentSha();

  /// 记账里**缺本机指纹**时把它补上（只补这一个键，别的一个字节不动）。
  ///
  /// 公开是给「检查更新」用的：它在"两边没有差别"那条分支上也能证明内容相同，
  /// 而那条分支是用户卡住时最可能点到的地方。**它是只读维护，不是同步** ——
  /// 不改 `syncedAt`、不写云端、不动数据。
  ///
  /// ## 为什么需要它
  ///
  /// `localSha` 是 2.3.0 才加的字段，而 **`analyzeSync` 判成 `noChange` 时
  /// 几条早退路径都不写记账** —— 那些路径恰恰是"两边内容确实是同一份"的证明。
  /// 于是老记账的 `localSha` 永远补不上，点阵屏上排永远空着（用户在真机上撞到了：
  /// 提示说"还没有数，同步成功过一次之后才会记下来"，可他点了推送却依然没有 ——
  /// 因为推送被正确地判定成"不需要推送"，而那条路不写记账）。
  ///
  /// ## 为什么在这里写是安全的
  ///
  /// 只在**已经判定两边内容相同**的路径上调用。所以"本机此刻的指纹"就等于
  /// "云端那一份的指纹"，记下来是**陈述一个已知事实**，不是猜。
  ///
  /// 三样东西故意不动：`syncedAt`（不是一次新的同步）、`recordCount`、
  /// `commitSha`/`remoteSha`（云端那一次提交没变）。所以补记之后
  /// 「上次同步」那行读起来照旧，只是点阵屏上排有了数。
  void rememberLocalShaIfMissing() {
    final record = storage.readSyncRecord();
    if (record == null || record.localSha.isNotEmpty) return;
    storage.writeSyncRecord(
      record.copyWith(localSha: workspace.localContentSha()),
    );
    notifyListeners();
  }

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
  /// 只接 [FileSystemException] 与 [StoreLockedByNewerSchema]：前者是磁盘/权限类问题，
  /// 后者是"盘上那份文件属于更新版本的 App、本次一个字节都没写"。
  /// 程序自身的 bug（类型错误等）仍旧照常抛出，不在生产环境里被悄悄咽掉。
  ///
  /// 为什么 [StoreLockedByNewerSchema] 必须在这里被接住并报出来（2026-10-01 修）：
  /// 在那之前 `AppStorage.save` 遇到这种情形是**静默 return** 的 —— 而 `run` 只认异常，
  /// 于是它 `notifyListeners()`、返回 `null`（= 成功），界面照报"改好了"，
  /// 用户整个会话的编辑在退出后全部消失。全仓其它"报成功但没写"的路径都已收口，
  /// **只剩这一处还在假装成功**。
  String? run(void Function() action) {
    final before = workspace.snapshotInMemory();
    try {
      action();
      notifyListeners();
      return null;
    } on RuleViolation catch (violation) {
      return violation.message;
    } on StoreLockedByNewerSchema {
      // 内存退回动作前：让界面与磁盘保持一致，用户看到的是"这次没生效"
      workspace.rollbackTo(before);
      notifyListeners();
      return '主数据文件由更新版本的 App 写入，本次改动没有保存。'
          '请升级 App 后再编辑 —— 现在继续改，改动在退出后会全部丢失。';
    } on FileSystemException catch (error) {
      // 内存退回动作前：宁可让界面"这次没生效"，也不能显示一个磁盘上没有的状态
      workspace.rollbackTo(before);
      notifyListeners();
      return '保存失败，这次改动没有写入磁盘：${error.message}。请检查存储空间后重试。';
    }
  }

  /// 节点是否展开；[defaultExpanded] 由调用方按节点状态给
  /// （任务框传的是"未完成→展开、已完成→收起"，于是"已完成自动折叠"是算出来的）。
  bool isExpanded(String id, {bool defaultExpanded = true}) =>
      prefs.isExpanded(id, defaultExpanded: defaultExpanded);

  void setExpanded(String id, {required bool expanded}) {
    workspace.setExpanded(id, expanded: expanded);
    notifyListeners();
  }

  void setLastTab(int index) {
    workspace.setLastTab(index);
    notifyListeners();
  }

  /// 从备份恢复（**会先把当前数据轮转进备份**，因此恢复动作本身也可回退）。
  String? restoreBackup(String path) {
    try {
      final restored = storage.restoreFromBackup(path);
      // 恢复会把主文件换掉、并把恢复前的那份轮转走 —— 备份集合变了，缓存必须作废（Q-4）
      _backupsCacheRevision = -1;
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

  /// 删掉某一份备份；返回 `null` 表示删掉了，否则是拒绝原因。
  ///
  /// 安全线（至少留一份、只认自己列的备份）在存储层，这里只负责转发与刷新。
  String? deleteBackup(String path) {
    final error = storage.deleteBackup(path);
    if (error == null) {
      _backupsCacheRevision = -1; // 删掉一份，缓存作废（Q-4）
      notifyListeners();
    }
    return error;
  }

  /// **只读**一份备份的内容，供"恢复之前先看差在哪"的差异面板用。
  ///
  /// 不动主文件、不写盘、不通知刷新：它只是把盘上那份读出来给界面比。
  /// 返回 `null` = 读不了 / 那份备份不可用，界面照实说。
  StoreFile? readBackupStore(String path) => storage.readBackupStore(path);

  /// 手动留一份备份（「立即备份一份」）：**强制轮转**，不等最小间隔。
  ///
  /// 不复用 `workspace.snapshotNow()` 的原因：那个走的是 `save()` 的节流路径，
  /// 而用户点这个按钮的意思就是"现在、立刻留一份"——节流会让这句话落空。
  /// 返回 `null` 表示成功。
  String? snapshotBackupNow() {
    // 轮转是**先把旧的往后挪、再把主文件复制成 backup.1**，所以 `backup.1` 的
    // 修改时刻变了，就说明这一次真的写出了一份新的。
    final newest = storage.paths.rollingBackup(1);
    final before = newest.existsSync() ? newest.lastModifiedSync() : null;

    try {
      storage.save(workspace.buildStoreFile(), forceRotate: true);
    } on StoreLockedByNewerSchema {
      // **理由必须对**（2026-10-01）：它原来是掉进下面那个
      // `on FileSystemException` 的，于是被锁住时会报"请检查存储空间或权限" ——
      // 而真实原因是"盘上那份文件属于更新版本的 App"。让用户去查存储空间
      // 是把他往错的方向支。
      return '主数据文件由更新版本的 App 写入，这次备份没有写。'
          '请升级 App 后再备份 —— 现在这份备份在磁盘上并不存在。';
    } on FileSystemException catch (error) {
      return '保存失败，这次备份没有写进磁盘：${error.message}。请检查存储空间后重试。';
    }

    // 主文件写成功 ≠ **这一次**的备份写成功（P1-3）。
    //
    // 判据是"新写出来了一份"（比 `backup.1` 的修改时刻），而不是"盘上存在一份"。
    // 为什么改：旧写法 `!rollingBackup(1).existsSync()` 问的是"盘上有没有"，
    // 而这里想知道的是"**这一次**写出来没有" —— 两件事只有在"上一次那份恰好
    // 还留在 backup.1"时才会分叉，而轮转的移位会先把旧的挪成 backup.2、
    // 顺手让备份数少一份，所以那个分叉**很难真的发生**（2026-10-01 试过构造，
    // 没构造成；旧写法在那条路径上也会给出正确结论）。
    //
    // 也就是说这次改的是**判据的语义**、不是修一个已发生的缺陷：新写法直接回答
    // 它想问的问题，不再依赖"移位一定会让旧的那份消失"这个间接性质。
    // 配套的收益是**可测**：`AtomicFile.copyHook` 让"备份写不出来"在 Windows 上
    // 也能确定性复现（原先只能靠只读目录，而 `attrib +R` 对目录不生效，
    // 用例退化成恒过）。
    final after = newest.existsSync() ? newest.lastModifiedSync() : null;
    if (after == null || after == before) {
      return '备份没有写进磁盘，本次备份未能保存。'
          '请检查存储空间或权限后重试；（主数据文件本身已保存）';
    }
    notifyListeners();
    return null;
  }

  // ------------------------------------------------------------ 实现计划的历史正文

  /// 某项目「实现计划」的历史正文（AI 覆盖之前那一版）；没有返回 `null`。
  String? implementationSnapshot(String projectId) =>
      storage.readImplementationSnapshot(projectId);

  /// 覆盖「实现计划」之前留一份旧正文（AI 预览页调用）。
  void saveImplementationSnapshot(String projectId, String text) =>
      storage.saveImplementationSnapshot(projectId, text);

  /// 当前正文（留档用；取不到项目时给空串）。
  String currentImplementation(String projectId) =>
      workspace.findProject(projectId)?.implementation ?? '';

  /// 把「实现计划」退回历史正文，然后**销掉这份历史**。
  ///
  /// 销掉是刻意的：一份历史只值一次反悔 —— 留着它，用户会以为"退回"可以反复按，
  /// 而第二次按下时退回的其实还是同一份，与预期不符。返回 `null` 表示成功。
  String? revertImplementation(String projectId) {
    final snapshot = storage.readImplementationSnapshot(projectId);
    if (snapshot == null) return '没有可退回的上一版';
    final error = run(() => workspace.replaceImplementation(projectId, snapshot));
    if (error != null) return error;
    storage.clearImplementationSnapshot(projectId);
    notifyListeners();
    return null;
  }

  // ------------------------------------------------------------ 重置（2026-09-28）

  /// 「重置」的范围：本级 + 它的所有直属下级。
  List<Project> resetScopeOf(String projectId) => workspace.resetScopeOf(projectId);

  /// 一次「重置」影响到的项目**条数**与**清单条目数**（确认框要用它说话）。
  ({int projects, int items}) resetImpactOf(String projectId) {
    final scope = resetScopeOf(projectId);
    var items = 0;
    for (final project in scope) {
      items += project.items.length;
    }
    return (projects: scope.length, items: items);
  }

  /// 执行一次「重置」，并在动手**之前**留一份可退回的档。
  ///
  /// [implementationsOnly] 为真 = 只清「实现」（正文 + 清单）；
  /// 为假 = 连「有什么问题 / 思路」（分类页的「总纲领」）一起清。
  ///
  /// [overrideIds] 把范围收窄：分类页的「重置下级所有实现」要**把自己摘掉**
  /// —— 分类的总纲领是它的定义，清掉等于把分类注销（2026-09-28 实机反馈：
  /// 重置的时候不应重置分类的总纲领）。
  ///
  /// 留档**先于**重置写盘，且写失败不阻断（与 AI 覆盖正文那一套同一条口径：
  /// 护栏失败不该挡住用户本来要做的事）。返回 `null` 表示成功。
  String? resetProject(
    String projectId, {
    required bool implementationsOnly,
    List<String>? overrideIds,
  }) {
    final ids = overrideIds ?? <String>[for (final p in resetScopeOf(projectId)) p.id];
    final byId = <String, Project>{
      for (final project in workspace.liveProjects) project.id: project,
    };
    final scope = <Project>[];
    for (final id in ids) {
      final each = byId[id];
      if (each != null) scope.add(each);
    }
    storage.saveResetSnapshot(<String, Map<String, dynamic>>{
      for (final project in scope)
        project.id: ProjectResetSnapshot(
          projectId: project.id,
          purpose: project.purpose,
          implementation: project.implementation,
          items: project.items,
        ).toJson(),
    });
    final error = run(
      () => implementationsOnly
          ? workspace.resetImplementations(ids)
          : workspace.resetProjects(ids),
    );
    if (error != null) return error;
    notifyListeners();
    return null;
  }

  /// 「清除已完成条目」：把范围内**已勾选**的清单条目删掉（跨项目、一次落盘）。
  ///
  /// 与 [resetProject] 的分工：那是"这些都作废了"，这里是"做完的归档掉" ——
  /// 清完只剩未完成项，可以接着排下一批。返回真正删掉的条数。
  int clearDoneItems(String projectId) {
    final scope = resetScopeOf(projectId);
    final removed = workspace.clearDoneItems(<String>[for (final p in scope) p.id]);
    if (removed > 0) notifyListeners();
    return removed;
  }

  /// 把上一次「重置」退回，然后**销掉这份留档**（一份只值一次反悔）。
  ///
  /// 返回 `null` 表示成功。留档在，但里面的项目**一个都不在了**（例如重置之后
  /// 又把它们删了）时也返回 `null` 并销掉留档 —— 那种情况下"没得退"是事实，
  /// 不该报错，更不该留着一个永远退不动的档。
  String? revertProjectReset() {
    final raw = storage.readResetSnapshot();
    if (raw == null) return '没有可退回的上一版';
    final snapshots = <ProjectResetSnapshot>[];
    for (final entry in raw.entries) {
      final snapshot = ProjectResetSnapshot.fromJson(entry.key, entry.value);
      if (snapshot != null) snapshots.add(snapshot);
    }
    if (snapshots.isEmpty) {
      storage.clearResetSnapshot();
      return '没有可退回的上一版';
    }
    final error = run(() => workspace.restoreResets(snapshots));
    if (error != null) return error;
    storage.clearResetSnapshot();
    notifyListeners();
    return null;
  }

  /// 现在有没有一份可退回的"重置之前"。
  bool get hasResetSnapshot => storage.readResetSnapshot() != null;

  // ------------------------------------------------------------ 导出 / 导入

  /// 导出整份数据并交给系统分享面板。
  ///
  /// **"落到私有目录"与"离开这台手机"是两件事**（2026-09-26 定的口径）：
  /// 文件写在应用私有目录里，用户一旦取消分享它就没出去，而卸载 App 会把私有目录
  /// 一起删掉。所以只有 [shareFile] 真的返回 `true` 才记一次"已导出"——
  /// 否则那句"超过 7 天没导出"的提醒不销账，用户不会被一个假账哄过去。
  Future<({bool ok, String message})> exportAndShare() async {
    try {
      final now = Ids.nowMillis();
      final bytes = ExportCodec.encode(workspace.buildStoreFile(), exportedAt: now);
      final file = storage.writeExport(bytes, nowMillis: now);
      final name = _fileNameOf(file.path);

      final shared = await shareFile(
        file.path,
        text: 'Guide Line 数据导出',
        subject: 'Guide Line 数据导出',
      );
      if (shared) {
        workspace.markExported(now);
        notifyListeners();
        return (ok: true, message: '已导出并分享：$name');
      }
      return (
        ok: true,
        message: '文件只落在应用私有目录：$name，没有离开手机，'
            '导出提醒不会销账；如需销账请成功分享一次。',
      );
    } catch (error) {
      return (ok: false, message: '导出失败：$error');
    }
  }

  /// 生成某项目的**交接说明**（Markdown）并交给系统分享面板。
  ///
  /// 与整库导出分开：这份只含**用户预览过的那一个项目**（目的、实现清单与正文、
  /// 待处理灵感、相关事件与任务线），用来丢给电脑上的 AI。
  /// 分享是否成功不影响文件本身 —— 它已经落在应用私有目录里了（也不涉及导出提醒）。
  Future<({bool ok, String message})> exportHandoffAndShare({
    required String projectId,
    required String markdown,
  }) async {
    try {
      final now = Ids.nowMillis();
      final project = workspace.findProject(projectId);
      final file = storage.writeHandoffExport(
        now,
        markdown,
        projectTitle: project?.title,
      );
      final name = _fileNameOf(file.path);
      final shared = await shareFile(
        file.path,
        text: '${project?.title ?? '项目'} · 交接说明',
        subject: '${project?.title ?? '项目'} · 交接说明',
      );
      return (
        ok: true,
        message: shared ? '已导出并分享：$name' : '文件只落在应用私有目录：$name，没有分享出去。',
      );
    } catch (error) {
      return (ok: false, message: '导出失败：$error');
    }
  }

  /// 把「**合并导入**」的结果落盘（Q25）。
  ///
  /// 与 [applyImport]（整体替换）的差别只在"结果是怎么来的"：合并结果由界面层
  /// 先调 `mergeStoresWithReport` 算出来、拿报告给用户看过（"多进来什么、覆盖了什么"），
  /// 确认之后才走到这里 —— 这一层只负责**落盘 + 重载**，不做任何合并判定。
  ///
  /// 走的是和 [restoreBackup] 同一条路：**强制轮转备份 → 原子写 → 重载工作区**。
  /// 强制轮转（而不是 [AppStorage.save] 的节流）是刻意的：用户刚确认过一次
  /// 覆盖性的合并，这一份"合并之前"的存档是他唯一的退路，不能因为
  /// "五分钟内刚存过"就被节流拦下 —— 那等于承诺了能退回却什么都没留。
  ///
  /// `savedAt` 由 [AppStorage.save] 记成此刻（契约 §2.1：仅供人看、不参与任何判定）。
  /// 返回 `null` 表示成功，否则是可以直接显示的失败文案。
  String? applyMergedStore(StoreFile merged) {
    try {
      storage.save(merged, forceRotate: true);
      workspace = Workspace.fromLoad(
        storage,
        LoadReport(
          store: merged,
          prefs: prefs,
          issues: DecodeIssues(),
          quarantinedPaths: const <String>[],
        ),
      );
      notifyListeners();
      return null;
    } catch (error) {
      return '合并失败：$error';
    }
  }

  /// 用导入的数据**整体替换**当前数据。
  ///
  /// 这是**覆盖性**操作，所以必须 `forceRotate`：先无条件把当前数据轮转进滚动备份，
  /// 「导错了文件」才有退路。不能用普通 `save`——那会被 5 分钟节流拦下，
  /// 用户在刚保存过之后导入，就等于直接覆盖、没有退路（P1-5）。
  String? applyImport(StoreFile store) {
    try {
      storage.save(store, forceRotate: true);
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

  // ---------------------------------------------------------------- AI

  /// AI 整理的总开关（偏好里的那个）。
  bool get aiEnabled => prefs.aiEnabled;

  /// 开 / 关 AI 整理。**只改"显不显示"**：地址、模型、Key 一律原样留着 ——
  /// 关掉是为了让界面清爽，不是"卸载功能"。
  void setAiEnabled(bool enabled) {
    if (enabled == prefs.aiEnabled) return;
    workspace.updatePrefs(prefs.copyWith(aiEnabled: enabled));
    notifyListeners();
  }

  /// 读当前 AI 配置（`apiKey` 从安全存储取，其余从偏好取）。
  ///
  /// `apiKey` 读不出来时当作"没配置"，**不报错** ——
  /// 部分 ROM 上 Keystore 会偶发失败，不该让设置页崩掉。
  Future<AiConfig> readAiConfig() async {
    final key = await credentials.readApiKey();
    return AiConfig(
      baseUrl: prefs.aiBaseUrl,
      apiKey: key ?? '',
      model: prefs.aiModel,
    );
  }

  /// 保存 AI 配置：非敏感部分进偏好，`apiKey` 进安全存储。
  Future<String?> saveAiConfig(AiConfig config) async {
    final normalized = config.normalized();
    try {
      workspace.updatePrefs(
        prefs.copyWith(aiBaseUrl: normalized.baseUrl, aiModel: normalized.model),
      );
      // 空 Key 表示"清掉"，不要把空串写进安全存储
      if (normalized.apiKey.isEmpty) {
        await credentials.clearApiKey();
      } else {
        await credentials.writeApiKey(normalized.apiKey);
      }
      // 配置改了就推进版本号：`MoreTab` 的副标题据此决定要不要重读一次
      // （它把 Future 缓存住了，见 Q-5）
      aiConfigRevision += 1;
      notifyListeners();
      return null;
    } catch (error) {
      return '保存失败：$error';
    }
  }

  /// AI 配置的版本号：每保存一次 +1。缓存了 [readAiConfig] 结果的界面用它判新旧。
  int aiConfigRevision = 0;

  /// 真发一次请求做连通性测试（设置页的「测试连接」）。
  ///
  /// 只发一句固定测试文字，**不带用户任何数据**；返回可直接显示的文案。
  /// 失败的文案里包含**实际请求的地址** —— 排查"连不上"时这是最关键的一条信息。
  Future<({bool ok, String message})> testAiConnection(AiConfig config) async {
    final normalized = config.normalized();
    final reason = normalized.validate();
    if (reason != null) return (ok: false, message: reason);

    try {
      final text = await ai.summarizeChecklist(
        config: normalized,
        input: const PromptInput(
          projectTitle: '连接测试',
          purpose: '',
          items: <({String text, bool done})>[(text: '测试一下', done: false)],
        ),
      );
      return (
        ok: true,
        message: '连通成功\n'
            '请求地址：${normalized.chatCompletionsUrl}\n'
            '模型：${normalized.model}\n'
            '模型回复：${text.trim()}',
      );
    } on AiRequestException catch (error) {
      return (
        ok: false,
        message: '连接失败\n请求地址：${normalized.chatCompletionsUrl}\n模型：${normalized.model}\n'
            '原因：${error.message}',
      );
    } catch (error) {
      return (ok: false, message: '连接失败：$error');
    }
  }

  /// 把项目清单交给模型整理成一段通顺说明（**只返回结果，不写库**）。
  ///
  /// 分成"生成"与"写回"两步是刻意的：模型可能编造清单里没有的东西，
  /// 必须让用户**先看到再确认**（《定义与边界》§10）。
  Future<({String? text, String? error})> summarizeProjectItems(String projectId) async {
    final project = workspace.findProject(projectId);
    if (project == null || project.deleted) return (text: null, error: '项目不存在');
    if (project.items.isEmpty) {
      return (text: null, error: '清单是空的，先加几条再整理');
    }

    final config = await readAiConfig();
    final reason = config.validate();
    if (reason != null) return (text: null, error: reason);

    try {
      final text = await ai.summarizeChecklist(
        config: config.normalized(),
        input: PromptInput(
          projectTitle: project.title,
          purpose: project.purpose,
          items: <({String text, bool done})>[
            for (final item in project.items) (text: item.text, done: item.done),
          ],
        ),
      );
      return (text: text, error: null);
    } on AiRequestException catch (error) {
      return (text: null, error: error.message);
    } catch (error) {
      return (text: null, error: '整理失败：$error');
    }
  }

  /// 把「如何解决」正文交给模型**拆成清单条目**（**只返回结果，不写库**）。
  ///
  /// 与 [summarizeProjectItems] 是**同一个功能的两个方向**，由界面上同一枚
  /// 按钮按"手上有什么"自动选（2026-09-28 实机反馈：拆这一步交给 AI）：
  ///   · 有清单 → 整理成正文；
  ///   · 清单为空、正文非空 → 拆成条目。
  ///
  /// 返回的是**一段文本，一行一条**（不是 `List`）：预览页那一个可编辑的编辑框
  /// 两种方向共用，用户改完再点写入。解析交回给 `Workspace.splitImplementationLines`
  /// —— 它本来就会丢掉 `-` / `1.` 这类记号，模型多写记号也不至于出错。
  Future<({String? text, String? error})> splitProjectItems(String projectId) async {
    final project = workspace.findProject(projectId);
    if (project == null || project.deleted) return (text: null, error: '项目不存在');
    if (project.implementation.trim().isEmpty) {
      return (text: null, error: '正文为空，请先填写正文再拆分。');
    }

    final config = await readAiConfig();
    final reason = config.validate();
    if (reason != null) return (text: null, error: reason);

    try {
      final text = await ai.splitIntoItems(
        config: config.normalized(),
        input: PromptInput(
          projectTitle: project.title,
          purpose: project.purpose,
          items: const <({String text, bool done})>[],
          implementation: project.implementation,
        ),
      );
      return (text: text, error: null);
    } on AiRequestException catch (error) {
      return (text: null, error: error.message);
    } catch (error) {
      return (text: null, error: '拆分失败：$error');
    }
  }

  // ------------------------------------------------- GitHub 备份同步

  /// 总开关关着时，推送 / 拉取一律拒绝的那句话。
  static const String _gitHubDisabledMessage =
      'GitHub 备份同步的开关尚未启用，请先在这一页打开「启用 GitHub 备份同步」';

  /// 「远程提交」那一行：**双端对版本的凭证**（ADR-089）。
  ///
  /// 读不到时如实写"读不到"，不写「未知」以外的任何东西 ——
  /// 这一行是给用户对版本的，含糊过去比不给更糟。
  static String _remoteCommitLine(RemoteCommit? commit) {
    if (commit == null || !commit.known) {
      return '远程提交：读不到。这个路径还没有提交，或者分支里一条提交都没有。';
    }
    final when = commit.committedAt == null ? '' : ' · ${formatStamp(commit.committedAt)}';
    return '远程提交：${shortSha(commit.sha)}$when';
  }

  /// 读 GitHub 备份同步的配置：非敏感部分在偏好里，Token 从安全存储取。
  ///
  /// 与 [readAiConfig] 同一口径：Token 读不出来当"没配置"，不报错 ——
  /// 部分 ROM 上 Keystore 偶发失败，不该让设置页崩掉。
  Future<({GitHubBackupConfig config, String token})> readGitHubBackupConfig() async {
    final token = await gitHubStore.readToken();
    return (
      config: GitHubBackupConfig(
        enabled: prefs.githubBackupEnabled,
        owner: prefs.githubBackupOwner,
        repo: prefs.githubBackupRepo,
        branch: prefs.githubBackupBranch,
        path: prefs.githubBackupPath,
      ),
      token: token ?? '',
    );
  }

  /// 保存 GitHub 备份同步的配置。
  ///
  /// 换仓库 / 分支 / 路径时**连记账一起清掉**：旧记账说的是"另一个落点上
  /// 我们同步到哪"，留着它会让冲突判定拿着错误的基线，把"两边都改过"
  /// 误判成"只有一边改过" —— 那正是最不该出错的一步。
  Future<String?> saveGitHubBackupConfig(
    GitHubBackupConfig config,
    String token,
  ) async {
    final cleaned = config.normalized();
    final old = prefs;
    final moved = cleaned.owner != old.githubBackupOwner ||
        cleaned.repo != old.githubBackupRepo ||
        cleaned.branch != old.githubBackupBranch ||
        cleaned.path != old.githubBackupPath;

    try {
      workspace.updatePrefs(
        prefs.copyWith(
          githubBackupEnabled: cleaned.enabled,
          githubBackupOwner: cleaned.owner,
          githubBackupRepo: cleaned.repo,
          githubBackupBranch: cleaned.branch,
          githubBackupPath: cleaned.path,
        ),
      );
      final trimmed = token.trim();
      if (trimmed.isEmpty) {
        await gitHubStore.clearToken();
      } else {
        await gitHubStore.writeToken(trimmed);
      }
      if (moved) storage.clearSyncRecord();
      gitHubConfigRevision += 1;
      notifyListeners();
      return null;
    } catch (error) {
      return '保存失败：$error';
    }
  }

  /// GitHub 配置的版本号：每保存一次 +1（缓存了读结果的界面用它判新旧）。
  int gitHubConfigRevision = 0;

  /// 上次与 GitHub 同步的记账（没同步过返回 null）。
  SyncRecord? readGitHubSyncRecord() => storage.readSyncRecord();

  /// 真连一次 GitHub：读一下远程那一份，证明 Token、仓库、分支都对。
  ///
  /// **只读不写** —— "测试连接"不该顺手往用户仓库里留东西。
  Future<({bool ok, String message})> testGitHubConnection(
    GitHubBackupConfig config,
    String token,
  ) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) return (ok: false, message: reason);
    if (token.trim().isEmpty) return (ok: false, message: '还没填 Token');

    const host = 'https://api.github.com';
    final where = '$host${cleaned.contentsApiPath}，分支 ${cleaned.branch}';

    try {
      final remote = await gitHub.readBackup(config: cleaned, token: token.trim());
      // 顺手读"远程此刻那一次提交"：只读一次，不写任何东西。
      // 它与文件内容一起，才答得出"远程停在哪一次上传"。
      final commit = await gitHub.latestCommit(config: cleaned, token: token.trim());
      if (remote == null) {
        // 404 有两种意思，Contents API 分不出来（ADR-090）：仓库 / 权限不对，
        // 或者仓库在、只是这份文件还没推过。旧写法一律说「连上了，远程还没有
        // 这份备份」—— owner 拼错也长这样，等于把配置错误报成了正常状态。
        final repo = await gitHub.describeRepository(
          config: cleaned,
          token: token.trim(),
        );
        final branchNote =
            repo.defaultBranch.isEmpty ? '' : '，默认分支 ${repo.defaultBranch}';
        return (
          ok: true,
          message: '连通成功：仓库 ${repo.fullName} 存在，'
              '${repo.isPrivate ? '私有' : '公开'}$branchNote。\n'
              '请求地址：$where\n'
              '${_remoteCommitLine(commit)}\n'
              '这个路径还没有备份，第一次「推送」会新建它；'
              '分支名写错也会得到同样的结果，请核对上面的默认分支。',
        );
      }
      if (!remote.readable) {
        return (
          ok: true,
          message: '连上了，但该文件读不出 Guide Line 数据。\n'
              '请求地址：$where\n'
              '${_remoteCommitLine(commit)}\n'
              '它可能不是本 App 推送的，推送会覆盖它。',
        );
      }
      return (
        ok: true,
        message: '连通成功\n'
            '请求地址：$where\n'
            '远程备份：${formatStamp(remote.savedAt)} · '
            '${liveRecordCount(remote.payload!.store)} 条活记录\n'
            '${_remoteCommitLine(commit)}',
      );
    } on GitHubBackupException catch (error) {
      return (ok: false, message: '连接失败\n请求地址：$where\n原因：${error.message}');
    } catch (error) {
      return (ok: false, message: '连接失败：$error');
    }
  }

  /// 看远程现在是什么状态（**只读**，供界面在推送 / 拉取前把情况摆清楚）。
  ///
  /// [remoteCommit] 是远程**此刻**那一次提交：推送前的确认框要把它摆出来，
  /// 用户才知道自己这次覆盖掉的是哪一次上传。
  ///
  /// [offline] 与 [error] 是**两个问题**：`error` 说"为什么没成"（给人看的那句话），
  /// `offline` 说"这算不算网络问题"（决定右上角摆黄胶囊还是红胶囊）。以前后者是
  /// 拿 `error` 这句中文去比对出来的（`looksOffline` 认"连不上"三个字），文案一改
  /// 就静默失配；现在由抛错的地方标（ADR-095）。
  Future<
      ({
        RemoteBackup? remote,
        RemoteCommit? remoteCommit,
        SyncPlan? plan,
        String? error,
        bool offline,
      })> checkGitHubBackup(
    GitHubBackupConfig config,
    String token,
  ) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) {
      return (
        remote: null,
        remoteCommit: null,
        plan: null,
        error: reason,
        offline: false,
      );
    }
    if (token.trim().isEmpty) {
      return (
        remote: null,
        remoteCommit: null,
        plan: null,
        error: '还没填 Token',
        offline: false,
      );
    }

    try {
      final remote = await gitHub.readBackup(config: cleaned, token: token.trim());
      final remoteCommit =
          await gitHub.latestCommit(config: cleaned, token: token.trim());
      final local = workspace.buildStoreFile();
      final plan = analyzeSync(
        local: local,
        // 本地那句 savedAt 要读**盘上**的：`buildStoreFile()` 现取 `now()`，
        // 拿它做基线的话本地永远"刚改过"（ADR-095 第 ④ 条）。
        localSavedAt: storage.readStoreSavedAt() ?? lastSyncedAt(),
        remote: remote,
        lastSync: storage.readSyncRecord(),
        // 需求④（ADR-093）：云端**此刻**那一次提交的码。它跟上次同步记账里那一个
        // 一致，就说明这中间没有第三方动过云端，本机可以直接覆盖上去。
        remoteCommitSha: remoteCommit?.sha ?? '',
      );
      return (
        remote: remote,
        remoteCommit: remoteCommit,
        plan: plan,
        error: null,
        offline: false,
      );
    } on GitHubBackupException catch (error) {
      return (
        remote: null,
        remoteCommit: null,
        plan: null,
        error: error.message,
        offline: looksOffline(error),
      );
    } catch (error) {
      return (
        remote: null,
        remoteCommit: null,
        plan: null,
        error: '读取远程失败：$error',
        offline: false,
      );
    }
  }

  // ── 回到主页的自动同步（handoff #87c57e） ──────────────────────────────
  //
  // 一条硬口径：**"覆盖式"的动作一律要人先看过差异**（ADR-091/092，延伸到 ADR-093）。
  // 本机的改动是本机发生的，自动传上去是顺水推舟；云端比本机新、或者两边都改过，
  // 是要覆盖掉某一边数据的动作 —— 那种事必须由人看着差异亲手点一次。
  //
  // ADR-093 在这一条上开了两处口子，都是有据可依的：
  //   · 云端的提交码跟上次同步记账**对得上** ⇒ 这中间没有第三方动过云端，本机直接
  //     覆盖上去（需求④）——"没人动过"本身就是"不必再看一眼"的理由；
  //   · 每次进软件先做一次**静默比对**（不转圈），不一致就把那扇面板端出来（需求⑤）。

  /// 自动同步的当前状态（标题栏右侧那枚指示器读它）。
  AutoSyncState autoSync = const AutoSyncState.idle();

  /// 自动同步停在"要不要把这份推上去"这一步时的差异（非 null ⇒ 外壳弹差异面板）。
  ///
  /// 为什么把这个存在控制器上而不是直接弹：弹面板要 `BuildContext`，而控制器是
  /// **不带界面**的。它把"该问了"这件事摆出来，外壳看到就来问 —— 于是
  /// 「比对 → 该推的推 / 有偏差才问」这一整条流程，在没有界面的测试里也能跑完。
  StoreDiff? pendingAutoPushDiff;

  /// 启动那次**静默比对**（需求⑤）攒下的待办：非 null ⇒ 外壳摆差异面板。
  ///
  /// 与 [pendingAutoPushDiff] 分开，是因为问的不是同一件事：那个问"这一次改的要推
  /// 上去，你看一眼"（按钮是推送 / 暂不推送），这个问"一进来就发现两边对不上，
  /// 你要用哪一边"（按钮是覆盖云端数据 / 使用云端数据）—— 面板同一扇，
  /// 按下去做的事不一样。
  StartupSyncRequest? pendingStartupSync;

  /// 启动比对连不上 GitHub 时要弹的那句警告；外壳弹完必须调
  /// [ackStartupOfflineWarning]。null = 这次不弹（连上了，或者今天已经弹过）。
  String? pendingStartupOfflineWarning;

  /// `done` 那颗绿胶囊自己收场的计时器（需求②：停 2 秒再按动画收掉）。
  Timer? _autoHideTimer;

  /// 绿胶囊停多久自己消失。纯计时、不联网，所以在没有界面的测试里也等得起。
  static const Duration autoSyncDoneLinger = Duration(seconds: 2);

  void _setAutoSync(AutoSyncState next) {
    if (next == autoSync) return;
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    autoSync = next;
    // 只有"传上去了"会自己收场：黄/红是"要你看一眼"的，常驻到下一次同步成功。
    if (next.phase == AutoSyncPhase.done) {
      _autoHideTimer = Timer(autoSyncDoneLinger, _hideAutoSyncDone);
    }
    notifyListeners();
  }

  void _hideAutoSyncDone() {
    _autoHideTimer = null;
    if (autoSync.phase != AutoSyncPhase.done) return;
    autoSync = const AutoSyncState.idle();
    notifyListeners();
  }

  @override
  void dispose() {
    // 计时器到点还会摸一次 notifyListeners：不在这里掐掉，退出界面之后就会炸。
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    super.dispose();
  }

  /// 今天（本地时区）的 `YYYY-MM-DD`。
  ///
  /// 「GitHub 未连接」的警告按**天**只弹一次（Q-6），所以存日期而不是时间戳：
  /// 过了零点，第二天开机就该重新提醒一次。
  static String todayKey([DateTime? now]) {
    final at = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)}';
  }

  /// 「回到主页」时跑一次：收掉编辑会话，**这一趟真的编辑过**才看一眼要不要传。
  ///
  /// **这里刻意不额外落盘**。handoff 说的"回到主页产生一次保存"，在 App 里
  /// 早就已经是"每一笔动作各自落一次盘"（`AppStorage.save` 由每个动作调），
  /// 回主页时盘上就是最新的；而在这里再补一次 `save` 不是"更保险"，是有害的：
  /// 主文件里的 `savedAt` 会被顶到现在，`analyzeSync` 于是永远判"本地改过"，
  /// 于是①每一次回主页都多推一个内容一字不差的提交，②本来只是**云端更新**
  /// 的情况会被判成"两边都改过"（那时本地时间戳凭空变新），把该拉的说成冲突。
  /// 所以这一次只做两件事：收会话，然后拿盘上的时间戳与云端比。
  ///
  /// 需求①（ADR-093）：以前是"每一次回主页都连一次网"，于是翻个列表、看一眼统计
  /// 也会转一次圈。现在闸门设在**"这一趟写没写过盘"**上
  /// （`AppStorage.editedSinceSessionStart`）：进编辑会话时记下基线，
  /// 出会话时对一下 —— 这一趟一条记录都没写过就直接收场，不联网、指示器也不出现。
  /// 闸门认的是"写没写过盘"，不是"点没点过界面"：
  /// 进了输入框又原样退出来、点了取消，都不算编辑。
  ///
  /// 比对结果是什么都不做时，指示器**回到静默**而不是留一个"已同步"：
  /// 那一下并没有传任何东西，摆个绿胶囊是骗人。
  Future<void> autoSyncAfterHome() async {
    // 要在 endEditSession() 之前问：会话基线是那时清掉的。
    final edited = storage.editedSinceSessionStart;
    storage.endEditSession();
    if (!edited) return;
    await _autoSyncOnce(announce: true);
  }

  /// 每次进软件跑一次**静默比对**（需求⑤）：不转圈，只看要不要摆差异面板。
  ///
  /// 与 [autoSyncAfterHome] 的分工：那条是"这一趟改过东西了，顺手传上去"，
  /// 这条是"开机先看一眼手上这份跟云端对不对得上"。总开关关着时**完全不联网**：
  /// 不弹窗、不画胶囊（用户口径）。
  Future<void> startupSyncCheck() => _autoSyncOnce(announce: false);

  /// 自动上传的**防重入闸**：这一趟还跑着就绝不另起一趟（ADR-095 第 ③ 条）。
  ///
  /// 为什么不用 `autoSync.isRunning` 当闸：那个状态只在 `announce = true` 时才置位，
  /// 而且**置位发生在第一个 await 之后** —— 手机外壳与桌面外壳各自在 `initState`
  /// 里喊一声"开机比对一次"，两趟就能同时挤进来（连两次网、弹两次面板）。
  /// 这个标记在方法**第一行**就立起来，`finally` 里放倒。
  bool _autoSyncInFlight = false;

  /// 拿盘上那句"本地数据最后一次落盘的时刻"当冲突判定的基线。
  ///
  /// 盘上还没有主数据文件时（本次运行一次都没写过盘）返回 [SyncRecord.syncedAt]，
  /// 也就是"上次同步的那一刻" —— 那一刻两边是一致的，于是"本地改过吗"这个问题
  /// 得到的答案是**没改过**，这正是事实。
  ///
  /// 以前这里退到 `local.savedAt`，而那个值来自 `buildStoreFile()` 现取的 `now()`
  /// （`Ids.nowMillis()`）：**一次都没编辑过的本机于是被判成"刚改过"**，
  /// 于是①每次回主页都白连一次网，②开机时还摆一扇"这台手机上也有改动"的面板
  /// 去问一个用户根本没做过的事（ADR-095 第 ④ 条）。
  int? lastSyncedAt() => storage.readSyncRecord()?.syncedAt;

  /// 比对一次，并按计划行事。
  ///
  /// [announce] = 要不要转那颗圆环。编辑后的自动同步转（用户要看它在动），
  /// 启动那次静默比对**不转** —— 需求⑤说的"不显示右上角圆环"。
  Future<void> _autoSyncOnce({required bool announce}) async {
    // 进门前上锁：下面每一个 await 都可能换出去，锁必须在这之前立起来。
    if (_autoSyncInFlight) return;
    _autoSyncInFlight = true;
    try {
      await _autoSyncOnceLocked(announce: announce);
    } finally {
      _autoSyncInFlight = false;
    }
  }

  Future<void> _autoSyncOnceLocked({required bool announce}) async {
    // 已经摆着一个待确认的差异时，不再叠第二次比对。
    if (pendingAutoPushDiff != null || pendingStartupSync != null) return;

    final saved = await readGitHubBackupConfig();
    // 总开关关着 = 别动网（含"我改主意了"）：连指示器都不出现。
    if (!saved.config.enabled) return;

    final local = workspace.buildStoreFile();

    if (announce) _setAutoSync(const AutoSyncState.running());
    final check = await checkGitHubBackup(saved.config, saved.token);
    if (check.error != null) {
      final reason = check.error!;
      // "算不算连不上"由抛错的地方标（ADR-095 第 ⑤ 条），不拿中文去比对。
      if (check.offline) {
        // 连不上：黄胶囊常驻（不自己消失），点开能看网络那句原话。
        _setAutoSync(AutoSyncState.offline(reason));
        // "继续编辑可能与云端产生差异"那句主动警告只在开机那一次（需求⑤）：
        // 编辑路上连不上时胶囊就在眼前，不必再打断一次。
        if (!announce) _offerOfflineWarning(reason);
      } else {
        _setAutoSync(AutoSyncState.failed(reason));
      }
      return;
    }
    final plan = check.plan;
    if (plan == null) {
      _setAutoSync(const AutoSyncState.failed('比对不出结果，请到同步页查看。'));
      return;
    }

    // 本机 0 条活记录：**先拦下来**，再谈别的（ADR-095 第 ② 条）。
    //
    // 为什么要单独提前到 switch 之前：`analyzeSync` 里"提交码对得上 ⇒ 直接覆盖"
    // 那一条排在 `localEmpty` **前面**（ADR-093 的位置口径），于是"本机 0 条 +
    // 云端仍是上次那次提交"会判成 `push/trustedOverwrite`，从这里直奔
    // `_pushAutoSync`，而 `pushGitHubBackup` 又会用 `localEmpty` 把它拒掉 ——
    // 白跑一趟网络，用户只收到一枚红胶囊，还看不到那扇"要不要把云端取回来"的
    // 面板。本机 0 条这件事比"云端有没有被别人动过"要紧，所以在这一层先判。
    if (liveRecordCount(local) == 0) {
      final remoteStore = check.remote?.payload?.store;
      final cloudHasRecords =
          remoteStore != null && liveRecordCount(remoteStore) > 0;
      if (!announce && cloudHasRecords) {
        pendingStartupSync = StartupSyncRequest(
          diff: diffStores(base: remoteStore, target: local),
          message: '云端备份里有 ${liveRecordCount(remoteStore)} 条记录，'
              '这台手机上一个字都还没有。可以先把云端那份取回来，'
              '取回之后两边就是同一份了。',
          pullOnly: true,
        );
      }
      _setAutoSync(
        AutoSyncState.blocked(label: '没有可上传的记录', reason: plan.message),
      );
      // 摆了面板就得喊一声：外壳靠这条通知去拿 `pendingStartupSync`。
      if (pendingStartupSync != null) notifyListeners();
      return;
    }

    switch (plan.action) {
      case SyncAction.noChange:
        // 两边本来就一样：没什么可说的，回到静默（不留一个"成功"骗人）。
        // **但要顺手把本机指纹补进记账**（见 [_rememberLocalShaIfMissing]）：
        // 这条分支是"内容确实是同一份"的**证明**，而它原来什么都不写 ——
        // 于是老记账（`localSha` 为空）永远补不上，点阵屏上排永远是空的。
        rememberLocalShaIfMissing();
        if (announce) _setAutoSync(const AutoSyncState.idle());
        return;
      case SyncAction.push:
        final remoteStore = check.remote?.payload?.store;
        // 远程那份读不出来（还没有这个文件 = 头一次同步）：没有旧版本可比，
        // 也就没什么可摆的，直接传。
        if (remoteStore == null) {
          await _pushAutoSync(saved.config, saved.token);
          return;
        }
        // 内容闸门：`analyzeSync` 判"该推"已经保证两边内容不同，这里再比一次是
        // 同一句话的第二道锁 —— 内容一条不差就绝不提交，不看提交码、不看时间戳。
        final diff = diffStores(base: remoteStore, target: local);
        if (!diff.hasChanges) {
          // 推上去只是把同一份内容再提交一次，没意义（ADR-091）。
          if (announce) _setAutoSync(const AutoSyncState.idle());
          return;
        }
        if (plan.trustedOverwrite) {
          // 需求④：云端还是上次同步留下的那一次提交 ⇒ 这中间没有第三方动过云端，
          // 本机这份直接覆盖上去 —— 不摆面板、不追问。
          await _pushAutoSync(saved.config, saved.token);
          return;
        }
        if (announce) {
          // 有偏差才问（用户口径：与云端比对后上传，出现偏差才弹差异面板）。
          pendingAutoPushDiff = diff;
        } else {
          // 开机这一次：提交码对不上、本机又有改动 ⇒ 摆面板让用户选"用哪一边"
          // （需求④⑤）。这扇面板的两个按钮都会改数据，所以点空白关不掉。
          pendingStartupSync = StartupSyncRequest(
            diff: diff,
            message: '云端数据已经不是上次同步过的那一次提交，提交码对不上，'
                '这台手机上也有改动。请选择保留哪一边的数据。',
          );
        }
        // 停在"等你决定"：黄胶囊把这件事摆在右上角（需求：不传也要说一声）。
        _setAutoSync(
          AutoSyncState.blocked(label: '本地有改动', reason: plan.message),
        );
        notifyListeners();
        return;
      case SyncAction.bothChanged:
      case SyncAction.pull:
        final remoteForChoice = check.remote?.payload?.store;
        final choiceDiff = remoteForChoice == null
            ? null
            : diffStores(base: remoteForChoice, target: local);
        if (!announce && choiceDiff != null && choiceDiff.hasChanges) {
          // 开机这一次：两边对不上，摆面板让用户选（需求⑤）。
          // 返回键 = 没选 = 一个字节没动，只把黄胶囊留在原处。
          pendingStartupSync = StartupSyncRequest(
            diff: choiceDiff,
            message: plan.action == SyncAction.pull
                ? '云端数据比这台手机新，提交码对不上。请选择保留哪一边的数据。'
                : '云端和这台手机都改过，提交码对不上。请选择保留哪一边的数据。',
          );
        }
        // 编辑路上（announce）刻意**不替用户拉**：拉下来会覆盖手上这份，
        // 那种事要在同步页上看着条数点确认（ADR-091）—— 这里只把原因摆出来。
        _setAutoSync(
          AutoSyncState.blocked(
            label: plan.action == SyncAction.pull ? '云端有更新' : '两边都改过',
            reason: plan.message,
          ),
        );
        notifyListeners();
        return;
      case SyncAction.localEmpty:
        // 走不到这里：本机 0 条在上面就拦掉了。留着这个分支是为了
        // switch 对枚举穷尽 —— 哪天 `analyzeSync` 多出一种"本机空"的动作，
        // 编译器会在这里提醒。
        _setAutoSync(
          AutoSyncState.blocked(label: '没有可上传的记录', reason: plan.message),
        );
        return;
    }
  }

  /// 用户在差异面板上点了「推送」：这一趟才真的传。
  Future<void> confirmPendingAutoPush() async {
    if (pendingAutoPushDiff == null) return;
    pendingAutoPushDiff = null;
    _setAutoSync(const AutoSyncState.running());
    final saved = await readGitHubBackupConfig();
    await _pushAutoSync(saved.config, saved.token);
  }

  /// 用户在差异面板上点了「暂不推送」：静默收场 —— 这是他选的，**不记成失败**。
  void cancelPendingAutoPush() {
    if (pendingAutoPushDiff == null) return;
    pendingAutoPushDiff = null;
    _setAutoSync(const AutoSyncState.idle());
  }

  /// 把这一趟自动上传做完，并把结果翻成指示器的状态。
  ///
  /// **`ok` 不等于"传上去了"**（ADR-095 第 ① 条）：`pushGitHubBackup` 在动手前
  /// 会再判一次，判出"两边本来就是同一份"（`noChange`）时它一个字节都不写、
  /// 只回一句 `ok: true`。那时候若照旧摆绿胶囊，提交码只能从记账里回读到
  /// **上一次**那一枚 —— 界面于是拿别人的号报这一趟的成功。
  /// 所以这里看 [PushOutcome.wrote]：没写就当作"这趟空转"，回静默。
  Future<void> _pushAutoSync(GitHubBackupConfig config, String token) async {
    final result = await pushGitHubBackup(config, token);
    _reportAutoPush(result);
  }

  /// 把一次推送的结果翻成右上角那个指示器该说的话。
  ///
  /// 三条出口，一条都不许少：
  ///   · 真写了（[PushOutcome.wrote]）→ 绿胶囊 + **这一次**的提交码
  ///     （`pushGitHubBackup` 刚写进记账的那一枚，直接从它手里拿，不回读）；
  ///   · 没成 → 红胶囊 + 原话；
  ///   · 成了但什么都没写（两边本来就是同一份）→ **回静默，不摆绿胶囊、
  ///     绝不报提交码**。为什么不摆一枚黄胶囊说这件事：空转不是"需要你看一眼"
  ///     的状态，摆上去就会**常驻到下一次同步成功**（黄胶囊的规矩），
  ///     等于每次多点一下都留一个永久提示。同一件事在 `_autoSyncOnce` 里也是
  ///     回静默（[SyncAction.noChange] 那句注释），两处口径一致。
  void _reportAutoPush(PushOutcome result) {
    if (!result.ok) {
      _setAutoSync(AutoSyncState.failed(result.message));
      return;
    }
    if (!result.wrote) {
      _setAutoSync(const AutoSyncState.idle());
      return;
    }
    _setAutoSync(AutoSyncState.done(result.commitSha));
  }

  /// 用户在开机那扇面板上点了「覆盖云端数据」：把本机这份推上去。
  ///
  /// 与自动推送的区别是这一步有**明确授权**：用户看过差异、亲手选了"用本机覆盖
  /// 云端"，所以连 pull / bothChanged 也让它过（等于在同步页上点过那第二次确认）。
  ///
  /// **本机 0 条活记录时这扇面板上不会出现这个按钮**（ADR-095 第 ② 条）：
  /// 那种情形下 `pushGitHubBackup` 一定会拒绝（读坏了也显示成 0 条，不拿空的
  /// 覆盖云端），面板给一个按了必然失败的按钮等于先承诺再反悔。
  /// 所以这里读的是**同一套出口**：拒绝就按拒绝报红，不另写一套"应该不会发生"。
  Future<void> acceptStartupPush() async {
    if (pendingStartupSync == null) return;
    pendingStartupSync = null;
    _setAutoSync(const AutoSyncState.running());
    final saved = await readGitHubBackupConfig();
    final result = await pushGitHubBackup(
      saved.config,
      saved.token,
      overrideRemoteChanges: true,
    );
    _reportAutoPush(result);
  }

  /// 用户在开机那扇面板上点了「使用云端数据」：拿云端那份覆盖本机。
  ///
  /// 覆盖之前会先轮转一次本地备份（[pullGitHubBackup] 里面做的），所以点错了
  /// 还能从备份里退回来。
  Future<void> acceptStartupPull() async {
    if (pendingStartupSync == null) return;
    pendingStartupSync = null;
    _setAutoSync(const AutoSyncState.running());
    final saved = await readGitHubBackupConfig();
    final result = await pullGitHubBackup(saved.config, saved.token);
    if (!result.ok) {
      _setAutoSync(AutoSyncState.failed(result.message));
      return;
    }
    // 拉下来之后本机就等于云端那一次提交：绿胶囊上摆的正是那个码。
    _setAutoSync(AutoSyncState.done(readGitHubSyncRecord()?.commitSha ?? ''));
  }

  /// 面板被返回键 / 划走关掉：**一个字节都没动**，只把待办清掉。
  ///
  /// 黄胶囊留着 —— 它本来就是"现在跟云端对不上"的常驻说明，不该跟着面板一起消失。
  void dismissStartupSync() {
    if (pendingStartupSync == null) return;
    pendingStartupSync = null;
    notifyListeners();
  }

  /// 连不上 GitHub：攒一句警告给外壳，同一天只弹一次（Q-6）。
  ///
  /// "今天弹过"是**在用户点掉警告时**才记的（见 [ackStartupOfflineWarning]）：
  /// 没点掉就关掉 App，下次开机还得再说一遍 —— 那句话本来就是提醒人心的。
  void _offerOfflineWarning(String reason) {
    if (pendingStartupOfflineWarning != null) return;
    if (storage.readOfflineWarnedOn() == todayKey()) return;
    pendingStartupOfflineWarning = reason;
    notifyListeners();
  }

  /// 外壳把"连不上 GitHub"的警告弹完了（用户点了「知道了」）：记下今天弹过。
  void ackStartupOfflineWarning() {
    if (pendingStartupOfflineWarning == null) return;
    pendingStartupOfflineWarning = null;
    storage.writeOfflineWarnedOn(todayKey());
    notifyListeners();
  }

  /// 把当前数据推到 GitHub（覆盖远程那一份）。
  ///
  /// [overrideRemoteChanges] 是用户在"两边都改过"时明确选了"用本地覆盖远程"。
  /// 不点它就不会覆盖 —— **这一条不许被界面绕过**：手机上把两份人生记录
  /// 自动并起来，比让用户手动选一次危险得多。
  ///
  /// 返回值见 [PushOutcome]：**`ok` 与"真的写了"是两件事** ——
  /// 判出"两边本来就是同一份"时它一个字节都不写，只回一句 `ok: true`。
  Future<PushOutcome> pushGitHubBackup(
    GitHubBackupConfig config,
    String token, {
    bool overrideRemoteChanges = false,
  }) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) return PushOutcome.failure(reason);
    // 总开关是用户手上的闸：关着就是"别动网"（含"我改主意了"）。
    // 界面会把按钮置灰，但灰按钮挡不住无障碍焦点与热键重入，所以这里再挡一次。
    if (!cleaned.enabled) return PushOutcome.failure(_gitHubDisabledMessage);
    if (token.trim().isEmpty) return PushOutcome.failure('还没填 Token');

    try {
      final remote = await gitHub.readBackup(config: cleaned, token: token.trim());
      // 提交码是**那一次提交**的码，不是内容 sha —— `RemoteBackup.sha` 答的是
      // "内容一不一样"，只有提交码答得上来"是不是同一次上传"（ADR-089）。
      // 空仓库 / 这个分支还没有提交时它是 null（客户端对 404、409 都回 null），
      // 于是提交码为空、`commitCodeMatches` 判"对不上"，照旧走正常那条路。
      final remoteCommit =
          await gitHub.latestCommit(config: cleaned, token: token.trim());
      final local = workspace.buildStoreFile();
      final plan = analyzeSync(
        local: local,
        // 盘上那句"本地最后一次落盘"；没落过盘就用上次同步那一刻
        // （见 [lastSyncedAt]：不拿"现在"顶替，否则本机永远"刚改过"）。
        localSavedAt: storage.readStoreSavedAt() ?? lastSyncedAt(),
        remote: remote,
        lastSync: storage.readSyncRecord(),
        // 与自动同步同一套判定（Q-4：手动页本质是自动推送的手动版）：
        // 提交码对得上就直接覆盖，不再要第二次确认。
        remoteCommitSha: remoteCommit?.sha ?? '',
      );

      if (plan.action == SyncAction.noChange) {
        // ⚠️ 这里**不写"同步成功"的账**：调用方必须看 [PushOutcome.wrote]
        // 再决定要不要说"传上去了"（ADR-095 第 ① 条）。
        //
        // 但**本机指纹要补**：这条分支正是"两边内容确实是同一份"的证明，
        // 不补的话老记账的 `localSha` 永远空着、点阵屏上排永远是暗的。
        rememberLocalShaIfMissing();
        return PushOutcome.unchanged('两边是同一份，没有要推的东西。');
      }
      if (plan.action == SyncAction.localEmpty) {
        return PushOutcome.failure(
          '${plan.message}\n\n'
          '为避免误覆盖远程数据，这里不再继续：请先在这台手机上恢复数据，或者到远程把备份保存下来。',
        );
      }
      if (plan.action == SyncAction.pull || plan.action == SyncAction.bothChanged) {
        if (!overrideRemoteChanges) {
          return PushOutcome.failure(
            '${plan.message}\n\n'
            '要覆盖远程请再点一次「推送」并在确认框里选「用本地覆盖远程」。',
          );
        }
      }

      final now = Ids.nowMillis();
      final bytes = ExportCodec.encode(local, exportedAt: now);
      final written = await gitHub.writeBackup(
        config: cleaned,
        token: token.trim(),
        bytes: bytes,
        message: commitMessageFor(
          nowMillis: now,
          recordCount: liveRecordCount(local),
          // 版本号从 platform 传进来：core 不许依赖 platform（分层硬线）。
          appVersion: AppInfo.versionLabel,
        ),
        knownSha: remote?.sha,
      );

      storage.writeSyncRecord(
        SyncRecord(
          syncedAt: now,
          remoteSha: written.sha,
          recordCount: liveRecordCount(local),
          commitSha: written.commitSha,
          // 同一刻本机这一份的指纹：点阵屏下排要摆它。
          localSha: workspace.localContentSha(),
        ),
      );
      notifyListeners();
      return PushOutcome.written(
        commitSha: written.commitSha,
        message: '已推送：${liveRecordCount(local)} 条记录 · ${formatStamp(now)}\n'
            '提交 ${shortSha(written.commitSha)} · 内容码 ${shortSha(written.sha)}\n'
            '远程路径：${cleaned.path}，分支 ${cleaned.branch}\n'
            '提交码是"同一次上传"的凭证：另一台手机上读到同一个码，就是同一份。',
      );
    } on GitHubBackupException catch (error) {
      return PushOutcome.failure('推送失败：${error.message}');
    } catch (error) {
      return PushOutcome.failure('推送失败：$error');
    }
  }

  /// 先把远程那份解出来（**不落盘**），给界面做"拉取前预览"。
  ///
  /// 单独一个方法是因为"用远程覆盖本地"是覆盖性操作：用户必须先看到
  /// **条数与时间**，点过确认，才允许调用 [pullGitHubBackup]。
  /// [commit] 是远程此刻那一次提交 —— 预览框里要摆出提交码，
  /// 用户才知道这次拉的是哪一次上传。
  Future<({RemoteBackup? remote, RemoteCommit? commit, String? error})> previewGitHubPull(
    GitHubBackupConfig config,
    String token,
  ) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) return (remote: null, commit: null, error: reason);
    if (!cleaned.enabled) {
      return (remote: null, commit: null, error: _gitHubDisabledMessage);
    }
    if (token.trim().isEmpty) return (remote: null, commit: null, error: '还没填 Token');

    try {
      final remote = await gitHub.readBackup(config: cleaned, token: token.trim());
      if (remote == null) {
        return (remote: null, commit: null, error: '远程还没有这份备份，先推送一次');
      }
      if (!remote.readable) {
        return (remote: null, commit: null, error: '远程备份读不出 Guide Line 数据');
      }
      if (liveRecordCount(remote.payload!.store) == 0) {
        return (
          remote: null,
          commit: null,
          error: '远程备份是 0 条记录，不算可用备份，不能用它覆盖本地。',
        );
      }
      final commit = await gitHub.latestCommit(config: cleaned, token: token.trim());
      return (remote: remote, commit: commit, error: null);
    } on GitHubBackupException catch (error) {
      return (remote: null, commit: null, error: error.message);
    } catch (error) {
      return (remote: null, commit: null, error: '读取远程失败：$error');
    }
  }

  /// 用远程那份**整体替换**本地数据（用户已经在预览里确认过）。
  ///
  /// 走 [applyImport] 同一条路：强制轮转备份 → 原子写 → 重载工作区，
  /// 所以"拉错了"还能在「备份与恢复」里退回。
  Future<({bool ok, String message})> pullGitHubBackup(
    GitHubBackupConfig config,
    String token,
  ) async {
    final preview = await previewGitHubPull(config, token);
    if (preview.remote == null) return (ok: false, message: preview.error ?? '读取远程失败');

    final remote = preview.remote!;
    final store = remote.payload!.store;
    final count = liveRecordCount(store);
    final commit = preview.commit;

    final error = applyImport(store);
    if (error != null) return (ok: false, message: '拉取失败：$error');

    final now = Ids.nowMillis();
    storage.writeSyncRecord(
      SyncRecord(
        syncedAt: now,
        remoteSha: remote.sha,
        recordCount: count,
        commitSha: commit?.sha ?? '',
        // 拉取之后两端内容一致，本机指纹就在这一刻记下。
        localSha: workspace.localContentSha(),
      ),
    );
    notifyListeners();
    return (
      ok: true,
      message: '已拉取远程备份：$count 条记录 · ${formatStamp(remote.savedAt)}\n'
          '提交 ${shortSha(commit?.sha ?? '')} · 内容码 ${shortSha(remote.sha)}\n'
          '拉取之前的本地数据已先轮转进备份，可在「备份与恢复」里退回。',
    );
  }

  /// 灵感箱空态那句轮换文案：**每次启动抽一次**，种子落进偏好（ADR-084）。
  ///
  /// 三个口径（2026-09-28 实机反馈定稿）：
  ///   · **每次启动都重抽** —— 上一版只在"没有种子"时抽，于是第二次开 App
  ///     还是同一句，看着像随机根本没生效；
  ///   · **同一次运行里不变**：界面只读这个种子，切页签 / 重建 / KeepAlive
  ///     回来都不会换句；
  ///   · 抽签放在这里而不是灵感页：灵感页会被反复重建，在那儿抽等于
  ///     "每进一次换一句"，晃眼而且像看错了。
  void rollEmptyBoxLine() {
    updatePrefs(prefs.copyWith(emptyBoxSeed: DateTime.now().microsecondsSinceEpoch));
  }

  /// 启动告警：把加载报告翻译成人能看懂的话。
  static List<String> buildWarnings(LoadReport report) {
    final warnings = <String>[];
    if (report.storeLockedByNewerSchema) {
      // 这条必须独占一句、而且要把"数据没丢"说清楚：
      // 用户看到的会是一个空库（本应用读不懂那份文件），最容易误判成"数据全没了"，
      // 从而做出"重新开始记"或"重新导入"这类会真正造成损失的动作。
      warnings.add(
        '数据文件由更新版本的 App 写入，本版本无法读取，已保持原样未改动。'
        '你的数据仍在文件里，升级 App 后即可看到；在此之前本版本的改动不会被保存。',
      );
      return warnings;
    }
    if (report.recoveredFromBackup != null) {
      warnings.add('主数据文件损坏，已从备份自动恢复');
    }
    if (report.quarantinedPaths.isNotEmpty) {
      warnings.add('检测到损坏文件，已隔离保留现场且未覆盖原文件：${report.quarantinedPaths.length} 个');
    }
    if (report.issues.errors.isNotEmpty) {
      warnings.add('解析时发现 ${report.issues.errors.length} 处问题，已按数据契约降级处理');
    }
    return warnings;
  }
}

/// 一次「推送到 GitHub」的结果（ADR-095 第 ① 条）。
///
/// 为什么不是 `({bool ok, String message})` 那个记录类型：那样**答不出**
/// "这一趟到底写没写远程"。而"推送"有三个结局，不是两个：
///   · 真提交了一次（[wrote] = true）；
///   · 没成（[ok] = false）；
///   · **成了，但一个字节都没写** —— 判定发现两边本来就是同一份
///     （[SyncAction.noChange]）。这一支也回 `ok: true`，可它**没有提交码可报**：
///     界面若照旧摆绿胶囊，就只能去记账里回读到**上一次**那一枚提交码，
///     于是把上一次的号说成这一次的（绿胶囊撒谎）。
///
/// 所以把"写没写"单独摆出来，让调用方没法忽略它。
class PushOutcome {
  const PushOutcome._({
    required this.ok,
    required this.wrote,
    required this.message,
    this.commitSha = '',
  });

  /// 没成：网络、Token、权限、本机 0 条、需要用户二次确认……
  const PushOutcome.failure(String message)
      : this._(ok: false, wrote: false, message: message);

  /// 成了，但远程**一个字都没改**（两边本来就是同一份）。
  const PushOutcome.unchanged(String message)
      : this._(ok: true, wrote: false, message: message);

  /// 真写了一次提交。[commitSha] 就是**这一次**的提交码。
  const PushOutcome.written({
    required String commitSha,
    required String message,
  }) : this._(ok: true, wrote: true, message: message, commitSha: commitSha);

  /// 这一趟有没有失败。
  final bool ok;

  /// 这一趟有没有**真的在远程写下一次提交**。false 时 [commitSha] 必为空串。
  final bool wrote;

  /// 给人看的那句话（失败原因 / 空转说明 / 成功摘要）。
  final String message;

  /// 这一次上传的提交码；没写就是**空串**（不是"未知"，是"这次没有"）。
  final String commitSha;
}

/// 把「推开一个页面 / 回到外壳」翻译成存储层的编辑会话。
///
/// 三条规则，都是为了"一段操作 = 一份备份"这件事不出错：
///   · **只认 `PageRoute`**：对话框、底部面板、弹出菜单都是 `PopupRoute`，
///     它们不算"进了另一个页面"，不该结束或重置会话；
///   · **跳过第一个路由**：外壳自己是 Navigator 的初始路由，它的 `previousRoute`
///     是 `null`。把它也算成"进页面"的话，App 一启动就永远停在会话里，
///     非会话那套最小间隔节流就再也不会生效；
///   · **按深度配对**：详情页里再推开一层时，只有回到外壳（深度归零）才算离开。
///     所以要数着开着的页面，不能见 push 就进、见 pop 就出。
class _EditSessionObserver extends NavigatorObserver {
  _EditSessionObserver({required this.onEnter, required this.onLeave});

  final void Function() onEnter;
  final void Function() onLeave;

  /// 当前推开的页面数（不含外壳自己）。
  int _openPages = 0;

  void _enter(Route<dynamic>? route, Route<dynamic>? previousRoute) {
    if (route is! PageRoute || previousRoute == null) return;
    _openPages += 1;
    if (_openPages == 1) onEnter();
  }

  void _leave(Route<dynamic>? route) {
    if (route is! PageRoute) return;
    if (_openPages == 0) return;
    _openPages -= 1;
    if (_openPages == 0) onLeave();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _enter(route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _leave(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _leave(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    // 替换（pushReplacement）目前一处都没用到，但漏掉它会让深度只增不减 ——
    // 一旦将来用上，会话就再也不结束了。按"旧的离开 + 新的进来"处理。
    if (oldRoute is! PageRoute) return;
    _leave(oldRoute);
    if (newRoute is! PageRoute) return;
    _openPages += 1;
    if (_openPages == 1) onEnter();
  }
}
