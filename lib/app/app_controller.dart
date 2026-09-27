import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core/ids.dart';
import '../core/json/store_file.dart';
import '../core/models/ai_config.dart';
import '../core/models/entity.dart';
import '../core/store/app_paths.dart';
import '../core/store/app_storage.dart';
import '../core/store/export_codec.dart';
import '../core/store/ui_prefs.dart';
import '../features/workspace.dart';
import '../platform/ai_client.dart';
import '../platform/data_directory.dart';
import '../platform/data_transfer_platform.dart';

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
  })  : startupWarnings = List<String>.unmodifiable(startupWarnings),
        ai = aiGenerator ?? const HttpAiTextGenerator(),
        credentials = credentialStore ?? const SecureAiCredentialStore(),
        shareFile = shareFile ?? _defaultShareFile;

  /// 从磁盘装配（唯一入口）。
  static Future<AppController> bootstrap({
    Directory? dataDirectoryOverride,
    AiTextGenerator? aiGenerator,
    AiCredentialStore? credentialStore,
    ShareFileHook? shareFile,
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
    ).._loadBackgroundBytes();
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
  late final NavigatorObserver editSessionObserver = _EditSessionObserver(
    onEnter: storage.beginEditSession,
    onLeave: storage.endEditSession,
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

  Workspace get ws => workspace;

  UiPrefs get prefs => workspace.prefs;

  int get projectCount => workspace.liveProjects.length;

  int get inspirationCount => workspace.inspirationInbox.length;

  int get eventCount => workspace.liveEvents.length;

  /// 任务总数：**排除已归档** —— 「更多 → 全部任务」页头那个「共 N 条（含子任务）」
  /// 用的就是它，入口副标题与页内数字必须是同一个数（Q20）。
  int get taskCount => workspace.liveTasks.where((t) => !t.archived).length;

  /// 归档区总数：**含第五个页签「被隐藏」**（Q20）。
  /// `ArchiveZone.totalCount` 只数前四个分区，页签上却摆了五个，入口写着
  /// "已归档 / 已丢弃 / 已合并 / 回收站 共 N 条"就对不上「被隐藏」那一档。
  int get archiveCount =>
      workspace.archiveZone.totalCount + workspace.inspirationsHiddenByArchivedProjects;

  /// **已逾期**：口径与算法**只有一处** —— `Workspace.overdueTasks()`（Q19）。
  ///
  /// 外壳的逾期横幅、底部「更多」的角标、以及落点页面「接下来的任务」里
  /// 「已逾期」那一组，三处调的是同一个函数，报的自然是同一个数。
  int get overdueCount => workspace.overdueTasks().length;

  /// **能搜到的东西有几条**（Q20）——「更多」入口那个「N 条内容可搜」用的就是它。
  ///
  /// 以前这里自己加了一遍 `projectCount + eventCount + taskCount + inspirationCount`：
  /// 四个 getter 里三个**含已归档**，而搜索实际只搜未归档的（灵感还只搜待处理的），
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

  /// 手动留一份备份（「立即备份一份」）：**强制轮转**，不等最小间隔。
  ///
  /// 不复用 `workspace.snapshotNow()` 的原因：那个走的是 `save()` 的节流路径，
  /// 而用户点这个按钮的意思就是"现在、立刻留一份"——节流会让这句话落空。
  /// 返回 `null` 表示成功。
  String? snapshotBackupNow() {
    try {
      storage.save(workspace.buildStoreFile(), forceRotate: true);
    } on FileSystemException catch (error) {
      return '保存失败，这次备份没有写进磁盘（${error.message}）。请检查存储空间后重试。';
    }
    // 主文件写成功 ≠ 备份写成功：**盘上真有这一份才算成功**（P1-3）。
    // 旧实现只据此返回 null；磁盘满时备份一份都没写出，界面却报"已备份一份"。
    if (!storage.paths.rollingBackup(1).existsSync()) {
      return '备份没有写进磁盘 —— 最近这一份没能留下，'
          '请检查存储空间或权限后重试（主数据文件本身已保存）。';
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
        message: '文件只落在应用私有目录（$name），没有离开手机 —— '
            '导出提醒不会销账；想销账请成功分享一次。',
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
        message: shared ? '已导出并分享：$name' : '文件只落在应用私有目录：$name（没有分享出去）',
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
  /// 必须让用户**先看到再确认**（设计文档 §2.2）。
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

  /// 启动告警：把加载报告翻译成人能看懂的话。
  static List<String> buildWarnings(LoadReport report) {
    final warnings = <String>[];
    if (report.storeLockedByNewerSchema) {
      // 这条必须独占一句、而且要把"数据没丢"说清楚：
      // 用户看到的会是一个空库（本应用读不懂那份文件），最容易误判成"数据全没了"，
      // 从而做出"重新开始记"或"重新导入"这类会真正造成损失的动作。
      warnings.add(
        '数据文件由更新版本的 App 写入，本版本读不懂，已保持原样未改动 —— '
        '你的数据还在文件里，升级 App 后即可看到；在此之前本版本的改动不会被保存。',
      );
      return warnings;
    }
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
