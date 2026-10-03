import 'dart:io';

import 'package:flutter/material.dart';
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

  group('老记账缺本机指纹时补记（2026-10-02）', () {
    // 背景：`localSha` 是 2.3.0 才加的字段，而 `analyzeSync` 判成 `noChange`
    // 时几条早退路径**都不写记账** —— 那些路径恰恰是"两边内容确实是同一份"的证明。
    // 于是老记账的 `localSha` 永远补不上，点阵屏上排永远空着；用户在真机上撞到：
    // 提示说"同步成功过一次之后才会记下来"，可他点推送依然没有 ——
    // 因为推送被**正确地**判成"不需要推送"，而那条路不写记账。
    test('判成"两边是同一份"时，把本机指纹补进记账，且不动别的时间/条数', () async {
      // 本机与云端内容一模一样（同一个 projects 数、同一个 savedAt）
      final same = storeWith(savedAt: now, projects: 2);
      final gateway = _FakeGateway(remote: remoteOf(same));
      final app = await bootWith(
        gateway: gateway,
        local: same,
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 2,
          commitSha: 'commit-old',
          // localSha 故意留空：模拟 2.3.0 之前写下的老记账
        ),
      );
      final expected = app.localContentSha;

      await app.autoSyncAfterHome();

      final record = app.readGitHubSyncRecord()!;
      expect(record.localSha, expected, reason: '补上了本机指纹');
      expect(
        record.syncedAt,
        now - 30000,
        reason: '这不是一次新的同步，时刻不许动',
      );
      expect(record.recordCount, 2, reason: '条数不许动');
      expect(record.commitSha, 'commit-old', reason: '云端那一次提交没变');
      expect(gateway.writeCount, 0, reason: '内容相同，绝不该往云端写');
    });

    test('判定"两边是同一份"时，把本机提交码也刷到刚读到的那一次（2026-10-02）', () async {
      // 用户原话："为什么本机提交码不会刷新"。
      // 本机不是 git 仓库，"本机跟着哪一次提交"只能从**读到的云端提交**得知；
      // 而这条出口读了云端却什么都不写（不提交、不记账）——
      // 于是下排永远停在旧号上，内容明明已经跟着云端走了。
      final same = storeWith(savedAt: now, projects: 2);
      final gateway = _FakeGateway(remote: remoteOf(same))
        ..commit = const RemoteCommit(sha: 'commit-old', message: '上次那次提交');
      final app = await bootWith(
        gateway: gateway,
        local: same,
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 2,
          commitSha: 'commit-old',
          localCommitSha: 'stale999',
        ),
      );

      await app.autoSyncAfterHome();

      expect(app.readGitHubSyncRecord()!.localCommitSha, 'commit-old',
          reason: '本机跟着的就是刚读到的这一次提交 —— 下排必须跟着刷新');
      expect(gateway.writeCount, 0, reason: '内容相同，绝不该往云端写');
    });

    test('推送成功后：本机提交码 = 刚写上去的那一次（不是"推之前那一次"）', () async {
      // 2026-10-02 真机 5 连击查出来的缺陷：推送把 `localCommitSha` 写成
      // **推之前**云端那一次（`remoteCommit`），于是本机每推一次、下排就落后一代，
      // 点阵屏上两排**永远"对不上"** —— 用户看到的就是"本机提交码不会刷新"。
      //
      // 正确语义：`localCommitSha` 回答"我手上这份内容在云端对应哪一次提交"。
      // 刚推完 ⇒ 云端那一次就是**刚写上去的这一次** ⇒ 两排本来就该一样。
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
      )..commit = const RemoteCommit(sha: 'commit-old', message: '推之前云端那一次');
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 3),
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 1,
          // 提交码对得上 ⇒ `trustedOverwrite` 直接放行，不摆面板。
          commitSha: 'commit-old',
          localCommitSha: 'commit-old',
        ),
      );

      await app.autoSyncAfterHome();

      final record = app.readGitHubSyncRecord()!;
      expect(record.commitSha, isNotEmpty);
      expect(
        record.localCommitSha,
        record.commitSha,
        reason: '刚推完：本机这份内容在云端就是刚写上去的那一次 —— 两排必须一致',
      );
      expect(
        record.localCommitSha,
        isNot('commit-old'),
        reason: '写成"推之前那一次"就是那个缺陷本身',
      );
    });

    test('已经有本机指纹时不重复写盘（不制造无谓的文件改动）', () async {
      final same = storeWith(savedAt: now, projects: 2);
      final gateway = _FakeGateway(remote: remoteOf(same));
      final app = await bootWith(
        gateway: gateway,
        local: same,
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 2,
          commitSha: 'commit-old',
          localSha: 'already',
        ),
      );

      final before = app.storage.readSyncRecord()!.localSha;
      await app.autoSyncAfterHome();

      expect(
        app.storage.readSyncRecord()!.localSha,
        before,
        reason: '已经有值就不动它 —— 乱写会无端改文件、多占一份备份',
      );
    });
  });

  group('总开关关着', () {    test('一次网都不连，指示器也不出现', () async {
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
        reason: '胶囊上要显示这一次的提交号（它自己回，不是猜的）',
      );
    });

    test('点「推上去」但那一趟其实没写远程：绝不许摆绿胶囊报提交号（ADR-095 第 ① 条）', () async {
      // 第二次判定（`pushGitHubBackup` 内部那一次）会走 noChange —— 它返回
      // `ok: true` 却一个字节都不写。旧写法这时从记账里回读到 **上一次**的提交码，
      // 于是界面拿旧号报这一趟的成功。
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
      expect(app.pendingAutoPushDiff, isNotNull, reason: '先得有那扇面板');

      // 用户还在这扇面板上时，别处把两边弄成了同一份（另一台设备推了同一份、
      // 或者本地又被拉回过一次）。这里直接把远程换成"和本机一模一样"。
      gateway.remote = remoteOf(storeWith(savedAt: now + 60000, projects: 2));

      await app.confirmPendingAutoPush();

      expect(gateway.writeCount, 0, reason: '内容没变就不该再提交一次');
      expect(
        app.autoSync.phase,
        isNot(AutoSyncPhase.done),
        reason: '没写远程就不是"传上去了"，绿胶囊与提交码都不许出现',
      );
      expect(app.autoSync.commitSha, isEmpty);
    });

    test('提交码对得上但内容没变：也不许摆绿胶囊（同一道闸的第二条路）', () async {
      final same = storeWith(savedAt: now - 60000, projects: 2);
      final gateway = _FakeGateway(remote: remoteOf(same))
        ..commit = const RemoteCommit(sha: 'commit-same', message: '上次那次提交');
      final app = await bootWith(
        gateway: gateway,
        local: same,
        record: SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 2,
          commitSha: 'commit-same',
        ),
      );

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0);
      expect(app.autoSync.phase, AutoSyncPhase.idle);
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
      expect(
        app.pendingStartupSync,
        isNull,
        reason: '编辑路上摆的是"要不要推"，本机空没有可推的',
      );
    });

    test('开机比对：摆一扇只给「使用云端数据」的面板（ADR-095 第 ② 条）', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 3)),
      );
      final app = await boot(gateway);
      await app.saveGitHubBackupConfig(configured, 'ghp_token');

      await app.startupSyncCheck();

      final request = app.pendingStartupSync;
      expect(request, isNotNull, reason: '本机空 + 云端有东西 ⇒ 该问"要不要把云端取回来"');
      expect(
        request!.pullOnly,
        isTrue,
        reason: '「覆盖云端数据」那一按必然被拒（空的盖不得远程），按钮就不该出现',
      );
      expect(request.diff.removed, 3, reason: '云端那三条要摆成"取回来就多出来的"');
      expect(app.autoSync.phase, AutoSyncPhase.blocked);
      expect(app.autoSync.label, '没有可上传的记录');
      expect(gateway.writeCount, 0, reason: '开机这一次绝不自己动数据');
    });

    test('提交码对得上也不许"直接覆盖"：本机 0 条时先拦下来再谈别的', () async {
      // 这一条钉的是一个具体的坑：`analyzeSync` 里"提交码对得上 ⇒ 直接覆盖"那一段
      // 排在 `localEmpty` **前面**（ADR-093 的位置口径），于是"本机 0 条 + 云端还是
      // 上次那次提交"会被判成 push/trustedOverwrite，直奔推送 —— 而推送又必然拒绝。
      // 白跑一趟网络、只收到一枚红胶囊，用户看不到那扇能把云端取回来的面板。
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 3)),
      )..commit = const RemoteCommit(sha: 'commit-same', message: '上次那次提交');
      final app = await boot(gateway);
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      app.storage.writeSyncRecord(
        SyncRecord(
          syncedAt: now - 30000,
          remoteSha: 'sha-remote',
          recordCount: 3,
          commitSha: 'commit-same',
        ),
      );

      await app.startupSyncCheck();

      expect(gateway.writeCount, 0, reason: '空的绝不能盖掉云端');
      expect(app.pendingStartupSync, isNotNull, reason: '该摆的是"把云端取回来"那扇');
      expect(app.pendingStartupSync!.pullOnly, isTrue);
      expect(app.autoSync.label, '没有可上传的记录');
    });

    test('点面板上那唯一的按钮：把云端取回来，本机就有记录了', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 3)),
      );
      final app = await boot(gateway);
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      await app.startupSyncCheck();

      await app.acceptStartupPull();

      expect(app.projectCount, 3, reason: '云端那三条要真的落到本机');
      expect(gateway.writeCount, 0, reason: '这一步只取不推');
      expect(app.autoSync.phase, AutoSyncPhase.done);
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
    test('同步记账与"今天已警告过"共用一份文件：写一边不能抹掉另一边', () async {
      // 独立核验查出：`writeSyncRecord` 是**整份覆盖** `github_sync.json`，
      // 而两个调用点都新建 `SyncRecord`、不带 `offlineWarnedOn` ——
      // 于是每同步成功一次就把"今天已经警告过连不上"抹掉，当天再断网会**重复弹**。
      // 反方向（`writeOfflineWarnedOn`）是**读回旧键再补一个**，两侧口径不对称。
      //
      // 这条用例只测"两个方向各改自己的键"，不牵扯任何网络。
      final app = await bootWith(
        gateway: _FakeGateway(),
        local: storeWith(savedAt: now - 60000, projects: 1),
        record: null,
      );

      app.storage.writeOfflineWarnedOn('2026-10-01');
      expect(app.storage.readOfflineWarnedOn(), '2026-10-01', reason: '前置：先记上一天');

      // 一次成功的同步只该改"同步记账"那几个键
      app.storage.writeSyncRecord(
        SyncRecord(
          syncedAt: now,
          remoteSha: 'sha-new',
          recordCount: 1,
          commitSha: 'commit-new',
        ),
      );

      expect(
        app.storage.readOfflineWarnedOn(),
        '2026-10-01',
        reason: '**不许把"今天已警告过"抹掉** —— 抹掉的话当天再断网会重复弹警告',
      );

      // 反方向也要成立：写同步记账之后，再记警告不能把记账抹掉
      app.storage.writeOfflineWarnedOn('2026-10-02');
      expect(
        app.storage.readSyncRecord()?.commitSha,
        'commit-new',
        reason: '反方向同样只改自己那个键（这一侧本来就是读回旧键再补，钉住它别退化）',
      );
      expect(app.storage.readOfflineWarnedOn(), '2026-10-02');
    });

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

  // ── 触发点：推开页面 → 真的改过 → 回到主页（ADR-095 第 ⑦ 条） ───────────
  //
  // 这一组钉的是**"谁在什么时候叫它干活"**。上面所有用例都是直接喊
  // `autoSyncAfterHome()` / `startupSyncCheck()` —— 也就是说，"回到主页那一下
  // 到底会不会喊"从来没被验过；而这一层恰恰是控制器里最绕的地方
  // （`NavigatorObserver` + 编辑会话深度 + 数据修订号三样凑在一起）。
  group('触发点：编辑会话怎么变成一次上传', () {
    /// 把控制器挂进一棵真树里，路由观察者与 App 里挂的是同一个
    /// （`main.dart` 那行 `navigatorObservers: [controller.editSessionObserver]`）。
    Future<void> pumpApp(WidgetTester tester, AppController app) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: <NavigatorObserver>[app.editSessionObserver],
          home: const Scaffold(body: Text('外壳')),
        ),
      );
    }

    /// 推一层进去 / 退一层出来（都用测试自己的时钟推完动画）。
    ///
    /// 刻意**不套 `tester.runAsync`**：这棵树里的每一个 await 都只等微任务
    /// （假远端的方法体是同步的、Token 也是内存里的），`pumpAndSettle` 就够；
    /// 套上 `runAsync` 反而要把每一个 `navigator` 引用搬进去，白饶一层。
    Future<NavigatorState> pushPage(WidgetTester tester, String label) async {
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: Text(label)),
        ),
      );
      await tester.pumpAndSettle();
      return navigator;
    }

    /// 回到主页那一下会触发一趟 `unawaited(...)` 的自动上传 —— 让它的 await 走完。
    Future<void> settleAutoSync(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(Duration.zero);
      }
    }

    /// 把绿胶囊那枚"停 2 秒自己收场"的计时器跑完。
    ///
    /// 不跑完的话用例会挂在 `A Timer is still pending even after the widget tree
    /// was disposed` 上 —— 那枚计时器属于控制器，而 `testWidgets` 结束时整棵树
    /// （连同假时钟）就被拆了。真机上不存在这件事：控制器活到进程结束。
    Future<void> drainDoneLinger(WidgetTester tester) async {
      await tester.pump(
        AppController.autoSyncDoneLinger + const Duration(milliseconds: 100),
      );
    }

    testWidgets('进页面看一眼、什么都没改就退回：一次网都不连', (tester) async {
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
      await pumpApp(tester, app);
      gateway.readCount = 0;
      gateway.writeCount = 0;

      final navigator = await pushPage(tester, '编辑页');
      navigator.pop();
      await tester.pumpAndSettle();
      await settleAutoSync(tester);

      expect(gateway.readCount, 0, reason: '没写过盘就别连网（需求①）');
      expect(gateway.writeCount, 0);
      expect(app.autoSync.phase, AutoSyncPhase.idle, reason: '连圆环都不该出现');
    });

    testWidgets('改过一笔再退回：门开着，该问的照问', (tester) async {
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
      await pumpApp(tester, app);
      gateway.readCount = 0;
      gateway.writeCount = 0;

      final navigator = await pushPage(tester, '编辑页');
      // "在详情页里改了一笔"：写盘那一笔就是这个 App 里每一次动作的落点。
      app.storage.save(app.ws.buildStoreFile());
      navigator.pop();
      await tester.pumpAndSettle();
      await settleAutoSync(tester);

      expect(gateway.readCount, greaterThan(0), reason: '改过了就该比一次');
      expect(gateway.writeCount, 0, reason: '有偏差要先问，不许自己覆盖云端');
      expect(app.pendingAutoPushDiff, isNotNull, reason: '该把差异摆出来等用户点');
    });

    testWidgets('推开的页面里再推一层：回到外壳才算离开（深度要配对）', (tester) async {
      final gateway = _FakeGateway();
      final app = await bootWith(
        gateway: gateway,
        local: storeWith(savedAt: now, projects: 2),
        record: null,
      );
      await pumpApp(tester, app);

      final navigator = await pushPage(tester, '详情');
      app.storage.save(app.ws.buildStoreFile());
      gateway.writeCount = 0;

      // 再推一层：这时**还没回到主页**，不该触发上传。
      await pushPage(tester, '再深一层');
      await settleAutoSync(tester);
      expect(gateway.writeCount, 0, reason: '详情页里再推一层不算"回到主页"');

      // 退一层：回到详情页，仍然不算回到主页。
      navigator.pop();
      await tester.pumpAndSettle();
      await settleAutoSync(tester);
      expect(gateway.writeCount, 0, reason: '退到详情页也没回到外壳');

      // 再退一层：这一次才是"回到主页"，门该开了。
      navigator.pop();
      await tester.pumpAndSettle();
      await settleAutoSync(tester);
      expect(gateway.writeCount, 1, reason: '回到外壳那一下才触发，而且只触发一次');
      await drainDoneLinger(tester);
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
      // `network: true` 就是"这句错是连不上"的结构化标记（ADR-095 第 ⑤ 条）：
      // 以前这里只给一句中文，靠 `looksOffline` 认"连不上"三个字，
      // 改一个词就会把离线说成"这次真的失败"。
      throw const GitHubBackupException(
        '连不上 GitHub：检查网络或代理设置',
        network: true,
      );
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
      throw const GitHubBackupException(
        '连不上 GitHub：检查网络或代理设置',
        network: true,
      );
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
