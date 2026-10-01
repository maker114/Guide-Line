import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/github_backup_config.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/core/store/github_sync.dart';
import 'package:guideline/platform/github_backup_client.dart';
import 'package:guideline/ui/app_shell.dart';

/// `AutoSyncPanels` —— **同步那些"要你看一眼"的弹窗**（ADR-095 第 ⑥ 条）。
///
/// 这一层是"控制器摆了待办、界面到底端没端出来"。它原来长在手机外壳里，
/// 加了电脑端之后桌面外壳没人端 —— 于是电脑上"开机比对发现两边对不上"只留下
/// 一枚黄胶囊，面板永远不出现。现在两个外壳挂的是同一份，所以这些用例都直接
/// 走 `AppShell`：它内部那棵就是真实接线（`AutoSyncPanels` 包着两个分支）。
///
/// 手机宽度下跑，是为了让树里那套手机外壳也一起建出来（面板与外壳同在）。
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
    tempDir = await Directory.systemTemp.createTemp('guideline_auto_panels');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Project project(String id) => Project(
        id: id,
        title: '指南线',
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

  RemoteBackup remoteOf(StoreFile store) => RemoteBackup.fromBytes(
        path: GitHubBackupConfig.defaultPath,
        sha: 'sha-remote',
        bytes: ExportCodec.encode(store, exportedAt: store.savedAt),
      );

  /// 起一份控制器并配好同步 —— 但**先不摆进树里**：待办要先攒好，
  /// 再挂上去看它会不会端出来（真机上这两件事的先后正是"开机比对还没回来，
  /// 外壳已经画好了"）。
  Future<AppController> bootReady(_FakeGateway gateway, StoreFile local) async {
    final app = await AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      gitHubGateway: gateway,
      gitHubCredentials: _FakeCredentials('ghp_token'),
    );
    await app.saveGitHubBackupConfig(configured, 'ghp_token');
    expect(app.applyImport(local), isNull, reason: '种一份本机数据');
    return app;
  }

  /// 把外壳摆进树里（窄宽度 = 手机那套，面板与外挂同一棵树）。
  Future<void> pumpShell(WidgetTester tester, AppController app) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(420, 900)),
        child: MaterialApp(home: AppShell(app: app)),
      ),
    );
    await tester.pumpAndSettle();
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

  testWidgets('回到主页有偏差：把差异面板端出来，点「推送」才真的传', (tester) async {
    final gateway = _FakeGateway(
      remote: remoteOf(storeWith(savedAt: now - 60000, projects: 1)),
    );
    final app = await bootReady(gateway, storeWith(savedAt: now, projects: 2));
    app.storage.writeSyncRecord(
      SyncRecord(
        syncedAt: now - 30000,
        remoteSha: 'sha-remote',
        recordCount: 1,
        commitSha: 'commit-old',
      ),
    );
    // 外壳挂上去之后才有监听者，所以待办要在这之前攒好（真机上是同一件事：
    // 控制器先摆出待办，外壳的监听随后被叫醒）。挂上树那一下 `initState`
    // 还会顺手起一次静默比对，这里先把它跑完。
    //
    // 编辑会话要**包住那一笔写盘**：需求①的门认的是"这段会话里改过没有"，
    // 先在会话里写、再出会话去问 —— 与用户"进详情页改一笔、退回主页"同序。
    app.storage.beginEditSession();
    app.storage.save(app.ws.buildStoreFile());
    await app.autoSyncAfterHome();
    expect(app.pendingAutoPushDiff, isNotNull, reason: '待办先攒好');

    await pumpShell(tester, app);

    expect(find.text('本次改动需要推送'), findsOneWidget, reason: '待办要真的弹出来');
    expect(find.text('推送'), findsOneWidget);
    expect(find.text('暂不推送'), findsOneWidget);

    await tester.tap(find.text('推送'));
    await tester.pumpAndSettle();

    expect(gateway.writeCount, 1, reason: '点了才传');
    await drainDoneLinger(tester);
  });

  testWidgets('开机比对发现本机 0 条：面板只给「使用云端数据」，不给覆盖', (tester) async {
    final gateway = _FakeGateway(
      remote: remoteOf(storeWith(savedAt: now - 60000, projects: 3)),
    );
    // 本机一个项目都没有 —— 云端那 3 条是唯一的来源。
    final app = await bootReady(gateway, storeWith(savedAt: now, projects: 0));

    await pumpShell(tester, app);

    expect(find.text('云端和这台手机对不上'), findsOneWidget);
    expect(
      find.text('覆盖云端数据'),
      findsNothing,
      reason: '空的盖不得远程：这个按钮按下去必然被拒，就不该出现（ADR-095 第 ② 条）',
    );
    expect(find.text('使用云端数据'), findsOneWidget, reason: '能做的只有把云端取回来');

    await tester.tap(find.text('使用云端数据'));
    await tester.pumpAndSettle();

    expect(app.projectCount, 3, reason: '云端那三条要真的落到本机');
    expect(gateway.writeCount, 0, reason: '这一步只取不推');
    await drainDoneLinger(tester);
  });

  testWidgets('开机比对发现两边都改过：两个按钮都在', (tester) async {
    final gateway = _FakeGateway(
      remote: remoteOf(storeWith(savedAt: now + 900000, projects: 3)),
    );
    final app = await bootReady(gateway, storeWith(savedAt: now, projects: 2));
    app.storage.writeSyncRecord(
      SyncRecord(
        syncedAt: now - 60000,
        remoteSha: 'sha-remote',
        recordCount: 1,
        commitSha: 'commit-old',
      ),
    );

    await pumpShell(tester, app);

    expect(find.text('云端和这台手机对不上'), findsOneWidget);
    expect(find.text('覆盖云端数据'), findsOneWidget, reason: '本机有东西，覆盖是允许的动作');
    expect(find.text('使用云端数据'), findsOneWidget);
  });

  testWidgets('连不上 GitHub：弹一次警告，点掉之后当天不再弹', (tester) async {
    final gateway = _FakeGateway(failRead: true);
    final app = await bootReady(gateway, storeWith(savedAt: now, projects: 2));

    await pumpShell(tester, app);

    expect(find.text('连不上 GitHub'), findsOneWidget, reason: '开机要主动说一句');
    expect(find.textContaining('连不上 GitHub：检查网络'), findsOneWidget, reason: '原话照摆');

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    expect(app.pendingStartupOfflineWarning, isNull);
    expect(
      app.storage.readOfflineWarnedOn(),
      AppController.todayKey(),
      reason: '点掉之后记的是"今天已经提醒过"',
    );

    // 再比对一次：同一天不该再弹（面板不会回来）。
    await app.startupSyncCheck();
    await tester.pumpAndSettle();
    expect(find.text('连不上 GitHub'), findsNothing);
  });
}

class _FakeGateway implements GitHubBackupGateway {
  _FakeGateway({this.remote, this.failRead = false});

  RemoteBackup? remote;
  RemoteCommit? commit;
  bool failRead;

  int readCount = 0;
  int writeCount = 0;

  @override
  Future<RemoteBackup?> readBackup({
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
