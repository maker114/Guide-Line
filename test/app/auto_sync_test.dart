import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/app/auto_sync_state.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/github_backup_config.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/core/store/github_sync.dart';
import 'package:guideline/platform/github_backup_client.dart';

/// 「回到主页自动上传」（handoff 双端同步 #87c57e）的**不带界面**那一半。
///
/// 这一层是自动同步最危险的地方：它会自己连网、自己写远程仓库，所以每一条
/// 都要能回答"凭什么它可以不等用户点"。口径（2026-09-30 改定，ADR-093）：
///   · 总开关关着**一次网都不连**；
///   · **真的改过东西才连网**（需求①）：这一趟编辑会话里一次盘都没写过，
///     回主页时连指示器都不出现；
///   · **只上传，从不自动覆盖式拉取** —— 云端更新、两边都改过、本机空，
///     这三种都只把原因摆出来（黄胶囊），交给人去决定；
///   · 有偏差先摆差异面板**等用户点**，没偏差才直接传；
///   · 唯一的例外是**提交码对得上**（需求④）：云端还是上次同步留下的那一次
///     提交 ⇒ 这中间没有第三方动过，本机这份直接覆盖上去；
///   · 每次进软件还会**静默比对**一次（需求⑤）：一致就什么都不说，对不上就攒一扇
///     面板等用户选，连不上就攒一句当天只弹一次的警告。
///
/// 说明：`storage.readStoreSavedAt()` 是"这次比对"的本地时间戳，而
/// `applyImport` 会把它盖成此刻 —— 所以想造出"本地没改过"的状态，
/// 记账里的 `syncedAt` 必须取**未来**的时刻（见下面各用例的时间戳）。
/// 反过来，`applyImport` 会真写一次盘，所以需求①那道理序门在这些用例里
/// 默认是放行的 —— 要验"没改过就不连网"，得自己再 `beginEditSession()` 一次。
void main() {
  late Directory tempDir;

  /// 用例开始的那一刻。往后推的时间戳都在它之上，免得受真实时钟抖动影响。
  final int now = DateTime.now().millisecondsSinceEpoch;

  const GitHubBackupConfig configured = GitHubBackupConfig(
    enabled: true,
    owner: 'maker114',
    repo: 'guideline-backup',
    branch: 'main',
    path: GitHubBackupConfig.defaultPath,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_auto_sync');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Project project(String id, {String title = '指南线'}) => Project(
        id: id,
        title: title,
        purpose: '目的',
        implementation: '实现',
        date: '2026-09-30',
        status: NodeStatus.pending,
        archived: false,
        parentProjectId: null,
        order: 1000,
        completedAt: null,
        createdAt: now,
        updatedAt: now,
        deleted: false,
      );

  StoreFile storeWith({required int savedAt, int projects = 1}) => StoreFile(
        savedAt: savedAt,
        documents: <DocName, Document>{
          for (final name in DocName.values) name: Document.empty(name),
          DocName.projects: Document(
            name: DocName.projects,
            items: <Entity>[for (var i = 0; i < projects; i++) project('p$i')],
          ),
        },
      );

  /// 远程那一份：走与真实推送完全相同的编码，免得验的是"我以为的形状"。
  RemoteBackup remoteOf(StoreFile store) => RemoteBackup.fromBytes(
        path: GitHubBackupConfig.defaultPath,
        sha: 'sha-remote',
        bytes: ExportCodec.encode(store, exportedAt: store.savedAt),
      );

  Future<AppController> boot(_FakeGateway gateway) => AppController.bootstrap(
        dataDirectoryOverride: tempDir,
        gitHubGateway: gateway,
        gitHubCredentials: _FakeCredentials('ghp_token'),
      );

  Future<AppController> bootWith({
    required _FakeGateway gateway,
    required StoreFile local,
    required SyncRecord? record,
    bool enabled = true,
  }) async {
    final app = await boot(gateway);
    await app.saveGitHubBackupConfig(configured.copyWith(enabled: enabled), 'ghp_token');
    if (record != null) app.storage.writeSyncRecord(record);
    expect(app.applyImport(local), isNull, reason: '种一份本机数据');
    return app;
  }

  group('总开关关着', () {
    test('一次网都不连，指示器也不出现', () async {
      final gateway = _FakeGateway(remote: remoteOf(storeWith(savedAt: now - 60000)));
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: null,
        enabled: false,
      );
      gateway.readCount = 0;

      await app.autoSyncAfterHome();

      expect(gateway.readCount, 0, reason: '关着就是别动网');
      expect(gateway.writeCount, 0);
      expect(app.autoSync.phase, AutoSyncPhase.idle, reason: '静默：连指示器都不该出现');
    });
  });

  group('本机改过、云端还是上次那份', () {
    test('摆出差异等用户点，绝不自己覆盖云端', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-old',
        ),
      );

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0, reason: '有偏差要先问，不许自己覆盖云端');
      final diff = app.pendingAutoPushDiff;
      expect(diff, isNotNull, reason: '该问的时候要把差异摆到外壳上');
      expect(diff!.added, 1, reason: '本机多出来的那条要标绿');
      expect(
        app.autoSync.phase,
        AutoSyncPhase.blocked,
        reason: '这件事还没完，别提前报成功（停在"等你点"上）',
      );
      expect(app.autoSync.label, '本地有改动', reason: '黄胶囊要说清停在哪一步');
      expect(app.pendingStartupSync, isNull, reason: '编辑路上摆的是"要不要推"，不是开机那扇');
    });

    test('点「推上去」：传一次，收一个绿色胶囊和提交号', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-old',
        ),
      );
      await app.autoSyncAfterHome();

      await app.confirmPendingAutoPush();

      expect(gateway.writeCount, 1);
      expect(app.pendingAutoPushDiff, isNull);
      expect(app.autoSync.phase, AutoSyncPhase.done);
      expect(
        app.autoSync.commitSha,
        'commit-written',
        reason: '胶囊上要显示这一次的提交号（从记账回读，不是猜的）',
      );
    });

    test('点「先不推」：静默收场，而且不算失败', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-old',
        ),
      );
      await app.autoSyncAfterHome();

      app.cancelPendingAutoPush();

      expect(app.pendingAutoPushDiff, isNull);
      expect(gateway.writeCount, 0);
      expect(
        app.autoSync.phase,
        AutoSyncPhase.idle,
        reason: '这是用户选的，不是"没能上传"',
      );
    });

    test('记录一条不差（只是时间戳被顶新）：不传，直接回静默', () async {
      final same = storeWith(savedAt: now - 60000, projects: 2);
      final gateway = _FakeGateway(remote: remoteOf(same));
      final app = await bootWith(
        gateway: gateway,
        local: same,
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 2,
          commitSha: 'commit-old',
        ),
      );

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0, reason: '同一份内容再提交一次只是噪音');
      expect(app.pendingAutoPushDiff, isNull);
      expect(app.autoSync.phase, AutoSyncPhase.idle);
    });
  });

  group('云端那头有新东西：只报原因，绝不自动拉回', () {
    test('云端更新：指示器说出原因，盘上一个字不动', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now + 1200000, projects: 3)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 1),
        record: SyncRecord(
          syncedAt: now + 600000,
          remoteSha: 'sha-remote',
          recordCount: 3,
          commitSha: 'commit-old',
        ),
      );
      final before = app.storage.readStoreSavedAt();

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0);
      expect(gateway.readCount, greaterThan(0));
      expect(app.autoSync.phase, AutoSyncPhase.blocked);
      expect(app.autoSync.label, '云端有更新');
      expect(app.autoSync.reason, contains('远程比本地新'));
      expect(app.storage.readStoreSavedAt(), before, reason: '自动同步不许动盘');
      expect(app.projectCount, 1, reason: '也不许把云端那份拉下来');
    });

    test('两边都改过：不替用户选，说清要去同步页决定', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now + 900000, projects: 3)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 60000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-old',
        ),
      );

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0);
      expect(app.autoSync.phase, AutoSyncPhase.blocked);
      expect(app.autoSync.label, '两边都改过');
      expect(app.autoSync.reason, contains('都改过'));
      expect(app.pendingAutoPushDiff, isNull, reason: '有分歧时连差异面板都不摆，先让人去同步页');
      expect(app.pendingStartupSync, isNull, reason: '编辑路上不替用户选');
    });
  });

  group('本机是空的', () {
    test('不拿空文件去覆盖云端，只说明原因', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 3)),
      );
      final app = await boot(gateway);
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      // 需求①的门：这一趟编辑会话里真写过盘，才轮到自动同步干活。
      app.storage.beginEditSession();
      app.storage.save(app.workspace.buildStoreFile());

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0);
      expect(app.autoSync.phase, AutoSyncPhase.blocked);
      expect(app.autoSync.label, '没有可上传的记录');
      expect(
        app.autoSync.reason,
        contains('本机当前没有记录'),
        reason: '读坏了也会显示成 0 条，所以只说明、不动手',
      );
    });
  });

  group('第一次同步', () {
    test('远程还没有这份文件：没有旧版本可比，直接传上去', () async {
      final gateway = _FakeGateway();
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: null,
      );

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 1);
      expect(app.autoSync.phase, AutoSyncPhase.done);
      expect(app.autoSync.commitSha, 'commit-written');
    });
  });

  group('连不上', () {
    test('网络/权限出错：指示器把原话摆出来，不当成"已同步"', () async {
      final gateway = _FakeGateway(failRead: true);
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: null,
      );

      await app.autoSyncAfterHome();

      expect(app.autoSync.phase, AutoSyncPhase.offline);
      expect(app.autoSync.label, 'GitHub 未连接');
      expect(app.autoSync.reason, contains('连不上'));
      expect(gateway.writeCount, 0);
      expect(
        app.pendingStartupOfflineWarning,
        isNull,
        reason: '编辑路上连不上不弹警告：胶囊就在眼前，不必再打断一次',
      );
    });
  });

  // ── 需求①：真的改过东西才连网（ADR-093） ──────────────────────────────
  group('需求①：只在真的改过东西之后才连网', () {
    test('推开页面看一眼就回来：一次网都不连', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-old',
        ),
      );
      // 会话开始，之后什么都没写 —— "进详情页看了一眼就退回主页"。
      app.storage.beginEditSession();
      gateway.readCount = 0;

      await app.autoSyncAfterHome();

      expect(gateway.readCount, 0, reason: '没改过就别连网（需求①）');
      expect(gateway.writeCount, 0);
      expect(app.autoSync.phase, AutoSyncPhase.idle, reason: '静默：连圆环都不该出现');
      expect(app.pendingAutoPushDiff, isNull);
    });

    test('真的改过：门开着，照常比对', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-old',
        ),
      );
      app.storage.beginEditSession();
      app.storage.save(app.workspace.buildStoreFile());

      await app.autoSyncAfterHome();

      expect(gateway.readCount, greaterThan(0), reason: '改过了就该比一次');
      expect(app.pendingAutoPushDiff, isNotNull, reason: '有偏差照旧摆面板等用户点');
    });
  });

  // ── 需求④：云端提交码没变就直接覆盖（ADR-093） ────────────────────────
  group('需求④：云端提交码对得上就直接覆盖', () {
    test('提交码对得上：不摆面板，直接推上去', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      )..commit = const RemoteCommit(sha: 'commit-same', message: '上次那次提交');
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-same',
        ),
      );

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 1, reason: '云端没被别人动过 ⇒ 本机直接覆盖云端');
      expect(app.pendingAutoPushDiff, isNull, reason: '这种情况不该再问一次');
      expect(app.autoSync.phase, AutoSyncPhase.done);
      expect(app.autoSync.commitSha, 'commit-written');
    });

    test('提交码对不上：仍然先摆差异，等用户点', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      )..commit = const RemoteCommit(sha: 'commit-other', message: '别人推的');
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-same',
        ),
      );

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0);
      expect(app.pendingAutoPushDiff, isNotNull, reason: '有第三方动过就得问');
      expect(app.autoSync.phase, AutoSyncPhase.blocked);
    });
  });

  // ── 需求⑤：开机静默比对（ADR-093） ────────────────────────────────────
  group('需求⑤：开机静默比对', () {
    test('两边一模一样：静默收场，圆环都不出现', () async {
      final same = storeWith(savedAt: now, projects: 2);
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 2)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: same,
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 2,
          commitSha: 'commit-old',
        ),
      );

      await app.startupSyncCheck();

      expect(gateway.writeCount, 0);
      expect(app.pendingStartupSync, isNull, reason: '一致就什么都不说（Q-A）');
      expect(app.pendingAutoPushDiff, isNull);
      expect(app.autoSync.phase, AutoSyncPhase.idle);
    });

    test('云端比本机新：攒一扇面板等用户选用哪一边', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now + 1200000, projects: 3)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 1),
        record: SyncRecord(
          syncedAt: now + 600000,
          remoteSha: 'sha-remote',
          recordCount: 3,
          commitSha: 'commit-old',
        ),
      );

      await app.startupSyncCheck();

      final request = app.pendingStartupSync;
      expect(request, isNotNull, reason: '对不上就摆面板（需求⑤）');
      expect(request!.message, contains('云端数据比这台手机新'));
      expect(request.diff.removed, greaterThan(0), reason: '要能把"少掉的那几条"摆出来');
      expect(app.autoSync.phase, AutoSyncPhase.blocked);
      expect(app.autoSync.label, '云端有更新');
      expect(gateway.writeCount, 0, reason: '开机这一次绝不自己动数据');
    });

    test('两边都改过：面板说清是两边都改过', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now + 900000, projects: 3)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: SyncRecord(
          syncedAt: now - 60000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          commitSha: 'commit-old',
        ),
      );

      await app.startupSyncCheck();

      expect(app.pendingStartupSync, isNotNull);
      expect(app.pendingStartupSync!.message, contains('云端和这台手机都改过'));
      expect(app.autoSync.label, '两边都改过');
    });

    test('点「覆盖云端数据」：推上去，收一个绿色胶囊', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now + 1200000, projects: 3)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 1),
        record: SyncRecord(
          syncedAt: now + 600000,
          remoteSha: 'sha-remote',
          recordCount: 3,
          commitSha: 'commit-old',
        ),
      );
      await app.startupSyncCheck();

      await app.acceptStartupPush();

      expect(gateway.writeCount, 1, reason: '用户明确选了"用本机覆盖云端"');
      expect(app.pendingStartupSync, isNull);
      expect(app.autoSync.phase, AutoSyncPhase.done);
      expect(app.projectCount, 1, reason: '本机那份没被动过');
    });

    test('点「使用云端数据」：拿云端覆盖本机', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now + 1200000, projects: 3)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 1),
        record: SyncRecord(
          syncedAt: now + 600000,
          remoteSha: 'sha-remote',
          recordCount: 3,
          commitSha: 'commit-old',
        ),
      );
      await app.startupSyncCheck();

      await app.acceptStartupPull();

      expect(app.projectCount, 3, reason: '拉下来之后本机就是云端那份');
      expect(app.pendingStartupSync, isNull);
      expect(app.autoSync.phase, AutoSyncPhase.done);
      expect(gateway.writeCount, 0, reason: '这一步只拉不推');
    });

    test('面板被关掉：一个字节没动，黄胶囊留着', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now + 1200000, projects: 3)),
      );
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 1),
        record: SyncRecord(
          syncedAt: now + 600000,
          remoteSha: 'sha-remote',
          recordCount: 3,
          commitSha: 'commit-old',
        ),
      );
      await app.startupSyncCheck();

      app.dismissStartupSync();

      expect(app.pendingStartupSync, isNull);
      expect(app.projectCount, 1, reason: '没选 = 什么都不做');
      expect(gateway.writeCount, 0);
      expect(
        app.autoSync.phase,
        AutoSyncPhase.blocked,
        reason: '黄胶囊是"现在跟云端对不上"的常驻说明，不跟着面板消失',
      );
    });

    test('连不上：攒一句警告，点掉之后当天不再弹', () async {
      final gateway = _FakeGateway(failRead: true);
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: null,
      );

      await app.startupSyncCheck();

      expect(app.autoSync.phase, AutoSyncPhase.offline);
      expect(app.pendingStartupOfflineWarning, contains('连不上'), reason: '开机要主动说一句');
      expect(app.storage.readOfflineWarnedOn(), isEmpty, reason: '还没点掉，先不记账');

      app.ackStartupOfflineWarning();

      expect(app.pendingStartupOfflineWarning, isNull);
      expect(
        app.storage.readOfflineWarnedOn(),
        AppController.todayKey(),
        reason: '点掉之后记的是"今天已经提醒过"',
      );

      await app.startupSyncCheck();

      expect(app.pendingStartupOfflineWarning, isNull, reason: '同一天只弹一次（Q-6）');
      expect(app.autoSync.phase, AutoSyncPhase.offline, reason: '胶囊照旧常驻');
    });
  });

  // ── 需求②：绿胶囊停 2 秒自己收场（计时在控制器上） ─────────────────────
  group('需求②：绿胶囊两秒后自己收场', () {
    test('传完之后停一会儿再回静默', () async {
      final gateway = _FakeGateway();
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: null,
      );

      await app.autoSyncAfterHome();

      expect(app.autoSync.phase, AutoSyncPhase.done);

      await Future<void>.delayed(
        AppController.autoSyncDoneLinger + const Duration(milliseconds: 250),
      );

      expect(app.autoSync.phase, AutoSyncPhase.idle, reason: '提交码不该一直挂着');
    });
  });
}

class _FakeGateway implements GitHubBackupGateway {
  _FakeGateway({this.remote, this.failRead = false});

  RemoteBackup? remote;
  RemoteCommit? commit;

  /// 让读远程这一步抛"连不上" —— 验失败态走的是同一套翻文案。
  bool failRead;

  int readCount = 0;
  int writeCount = 0;
  String lastMessage = '';

  @override
  Future<RemoteBackup?> readBackup({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    readCount += 1;
    if (failRead) {
      throw const GitHubBackupException('连不上 GitHub：检查网络或代理设置');
    }
    return remote;
  }

  @override
  Future<RemoteCommit?> latestCommit({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    readCount += 1;
    if (failRead) {
      throw const GitHubBackupException('连不上 GitHub：检查网络或代理设置');
    }
    return commit;
  }

  @override
  Future<RemoteRepository> describeRepository({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    readCount += 1;
    return const RemoteRepository(
      fullName: 'maker114/guideline-backup',
      isPrivate: true,
      defaultBranch: 'main',
    );
  }

  @override
  Future<RemoteBackup> writeBackup({
    required GitHubBackupConfig config,
    required String token,
    required List<int> bytes,
    required String message,
    required String? knownSha,
  }) async {
    writeCount += 1;
    lastMessage = message;
    final written = RemoteBackup.fromBytes(
      path: config.path,
      sha: 'sha-written',
      bytes: bytes,
      commitSha: 'commit-written',
    );
    remote = written;
    commit = RemoteCommit(sha: 'commit-written', message: message);
    return written;
  }
}

class _FakeCredentials implements GitHubCredentialStore {
  _FakeCredentials(this._token);

  String? _token;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> writeToken(String value) async => _token = value;

  @override
  Future<void> clearToken() async => _token = null;
}
