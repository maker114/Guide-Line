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
/// 都要能回答"凭什么它可以不等用户点"。口径（2026-09-30 定）：
///   · 总开关关着**一次网都不连**；
///   · **只上传，从不自动覆盖式拉取** —— 云端更新、两边都改过、本机空，
///     这三种都只把原因摆出来，交给人去同步页决定；
///   · 有偏差先摆差异面板**等用户点**，没偏差才直接传；
///   · 比对结果是什么都不用做时，指示器回静默，不留一个"已同步"骗人。
///
/// 说明：`storage.readStoreSavedAt()` 是"这次比对"的本地时间戳，而
/// `applyImport` 会把它盖成此刻 —— 所以想造出"本地没改过"的状态，
/// 记账里的 `syncedAt` 必须取**未来**的时刻（见下面各用例的时间戳）。
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
      expect(app.autoSync.isRunning, isTrue, reason: '这件事还没完，别提前报成功');
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
      expect(app.autoSync.phase, AutoSyncPhase.failed);
      expect(app.autoSync.reason, contains('比这台手机新'));
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
      expect(app.autoSync.phase, AutoSyncPhase.failed);
      expect(app.autoSync.reason, contains('都改过'));
      expect(app.pendingAutoPushDiff, isNull, reason: '有分歧时连差异面板都不摆，先让人去同步页');
    });
  });

  group('本机是空的', () {
    test('不拿空文件去覆盖云端，只说明原因', () async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: now - 60000, projects: 3)),
      );
      final app = await boot(gateway);
      await app.saveGitHubBackupConfig(configured, 'ghp_token');

      await app.autoSyncAfterHome();

      expect(gateway.writeCount, 0);
      expect(app.autoSync.phase, AutoSyncPhase.failed);
      expect(app.autoSync.reason, contains('空文件'));
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

      expect(app.autoSync.phase, AutoSyncPhase.failed);
      expect(app.autoSync.reason, contains('连不上'));
      expect(gateway.writeCount, 0);
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
