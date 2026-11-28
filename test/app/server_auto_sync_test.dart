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
import 'package:guideline/core/models/server_backup_config.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/core/store/github_sync.dart';
import 'package:guideline/platform/github_backup_client.dart';
import 'package:guideline/platform/server_backup_client.dart';

/// 服务器同步的**自动那一半**（不带界面）。
///
/// 口径（2026-11-28 用户要求）：
///   · 两条同步只能开一条，开一条就把另一条关掉；
///   · 本机有改动、服务器没动 ⇒ 自动推；
///   · 服务器有新版本、本机自上次同步后没改过 ⇒ 自动拉并刷新界面；
///   · 两边都改过 ⇒ 只摆面板，不自动覆盖；
///   · 本机 0 条 ⇒ 绝不推，服务器有数据时只给「使用服务器数据」。
void main() {
  late Directory tempDir;
  final int now = DateTime.now().millisecondsSinceEpoch;

  const configured = ServerBackupConfig(
    enabled: true,
    baseUrl: 'https://sync.example:8443',
    fingerprint:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_server_auto');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Project project(String id, {String title = '指南线'}) => Project(
        id: id,
        title: title,
        purpose: '目的',
        implementation: '实现',
        date: '2026-11-28',
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

  RemoteBackup remoteOf(StoreFile store, {int revision = 1}) =>
      RemoteBackup.fromBytes(
        path: '/v1/backup',
        sha: 'sha-${store.savedAt}',
        bytes: ExportCodec.encode(store, exportedAt: store.savedAt),
        commitSha: '$revision',
      );

  ServerMeta metaOf(RemoteBackup remote, int revision) => ServerMeta(
        revision: revision,
        sha256: remote.sha,
        size: remote.bytes.length,
        savedAt: remote.savedAt ?? 0,
        recordCount: remote.recordCount,
        appVersion: '2.12.0+106',
        updatedAt: now,
      );

  Future<AppController> boot(_FakeServerGateway gateway) =>
      AppController.bootstrap(
        dataDirectoryOverride: tempDir,
        serverGateway: gateway,
        serverCredentials: const _FakeServerCredentials('server-token'),
        gitHubCredentials: const _FakeGitHubCredentials('ghp_token'),
      );

  /// 打开服务器这条但**不触发**自动循环（循环只由外壳 / 保存动作启动）。
  Future<AppController> bootWithServer(
    _FakeServerGateway gateway, {
    required StoreFile local,
    int projects = 1,
  }) async {
    final app = await boot(gateway);
    app.workspace.updatePrefs(
      app.prefs.copyWith(
        serverSyncEnabled: true,
        serverSyncBaseUrl: configured.baseUrl,
        serverSyncFingerprint: configured.fingerprint,
      ),
    );
    expect(app.applyImport(local), isNull);
    return app;
  }

  SyncRecord recordOf(AppController app, {required int revision, String? remoteSha}) =>
      SyncRecord(
        syncedAt: app.storage.readStoreSavedAt() ?? now,
        remoteSha: remoteSha ?? 'sha-${revision - 1}',
        recordCount: 1,
        commitSha: '$revision',
        localSha: app.localContentSha,
        localCommitSha: '$revision',
      );

  group('两条同步互斥', () {
    test('开服务器就把 GitHub 关掉；开 GitHub 就把服务器关掉', () async {
      final app = await boot(_FakeServerGateway());
      expect(
        await app.saveGitHubBackupConfig(
          const GitHubBackupConfig(
            enabled: true,
            owner: 'maker114',
            repo: 'guideline-backup',
            branch: 'main',
            path: GitHubBackupConfig.defaultPath,
          ),
          'ghp_token',
        ),
        isNull,
      );
      expect(app.prefs.githubBackupEnabled, isTrue);

      expect(await app.saveServerBackupConfig(configured, 'server-token'), isNull);
      expect(app.prefs.serverSyncEnabled, isTrue);
      expect(app.prefs.githubBackupEnabled, isFalse, reason: '两条只能开一条');

      expect(
        await app.saveGitHubBackupConfig(
          const GitHubBackupConfig(
            enabled: true,
            owner: 'maker114',
            repo: 'guideline-backup',
            branch: 'main',
            path: GitHubBackupConfig.defaultPath,
          ),
          'ghp_token',
        ),
        isNull,
      );
      expect(app.prefs.githubBackupEnabled, isTrue);
      expect(app.prefs.serverSyncEnabled, isFalse);
      app.dispose();
    });
  });

  group('自动推送', () {
    test('服务器上还没有备份：本机有记录就自动建一份', () async {
      final gateway = _FakeServerGateway();
      final app = await bootWithServer(
        gateway,
        local: storeWith(savedAt: now, projects: 2),
      );

      await app.serverAutoSyncNow();

      expect(gateway.writeCount, 1);
      final record = app.readServerSyncRecord();
      expect(record, isNotNull);
      expect(record!.commitSha, '1');
      expect(app.serverAutoSync.phase, AutoSyncPhase.done);
      app.dispose();
    });

    test('本机改过、服务器没动：自动推，不摆面板', () async {
      final gateway = _FakeServerGateway();
      final app = await bootWithServer(
        gateway,
        local: storeWith(savedAt: now - 60000, projects: 1),
      );
      app.storage.writeServerSyncRecord(
        recordOf(app, revision: 1, remoteSha: 'sha-old'),
      );
      // 改一笔：内容指纹变了，服务器那条还停在 1。
      app.run(() => app.ws.updateProject('p0', title: '改过'));

      await app.serverAutoSyncNow();

      expect(gateway.writeCount, 1);
      expect(app.pendingServerSync, isNull);
      expect(app.serverAutoSync.phase, AutoSyncPhase.done);
      app.dispose();
    });
  });

  group('自动拉取', () {
    test('服务器有新版本、本机没改过：直接拉下来并刷新', () async {
      final gateway = _FakeServerGateway();
      final local = storeWith(savedAt: now - 60000, projects: 1);
      final app = await bootWithServer(gateway, local: local);
      final base = recordOf(app, revision: 1);
      app.storage.writeServerSyncRecord(base);

      final remote = remoteOf(storeWith(savedAt: now, projects: 3), revision: 2);
      gateway.remote = remote;
      gateway.meta = metaOf(remote, 2);

      await app.serverAutoSyncNow();

      expect(app.projectCount, 3, reason: '服务器那份已经覆盖到本机');
      expect(app.readServerSyncRecord()!.commitSha, '2');
      expect(gateway.writeCount, 0);
      expect(app.pendingServerSync, isNull);
      expect(app.serverAutoSync.phase, AutoSyncPhase.done);
      app.dispose();
    });

    test('服务器版本变了但内容没变：只对齐记账，不下载', () async {
      final gateway = _FakeServerGateway();
      final local = storeWith(savedAt: now, projects: 2);
      final app = await bootWithServer(gateway, local: local);
      app.storage.writeServerSyncRecord(
        recordOf(app, revision: 1, remoteSha: 'same-sha'),
      );

      final remote = remoteOf(local, revision: 2);
      gateway.remote = remote;
      gateway.meta = ServerMeta(
        revision: 2,
        sha256: 'same-sha',
        size: remote.bytes.length,
        savedAt: remote.savedAt ?? 0,
        recordCount: remote.recordCount,
      );

      await app.serverAutoSyncNow();

      expect(app.readServerSyncRecord()!.commitSha, '2');
      expect(gateway.readBackupCount, 0, reason: '内容一样就不该下载整份');
      expect(gateway.writeCount, 0);
      app.dispose();
    });
  });

  group('不动手的那几条', () {
    test('两边都改过：只摆面板，不给任何一边覆盖', () async {
      final gateway = _FakeServerGateway();
      final local = storeWith(savedAt: now - 60000, projects: 1);
      final app = await bootWithServer(gateway, local: local);
      app.storage.writeServerSyncRecord(recordOf(app, revision: 1));
      app.run(() => app.ws.updateProject('p0', title: '本机改过'));

      final remote = remoteOf(storeWith(savedAt: now, projects: 5), revision: 2);
      gateway.remote = remote;
      gateway.meta = metaOf(remote, 2);

      await app.serverAutoSyncNow();

      expect(app.pendingServerSync, isNotNull);
      expect(app.pendingServerSync!.pullOnly, isFalse);
      expect(app.projectCount, 1, reason: '面板还没选，本机数据不许动');
      expect(gateway.writeCount, 0, reason: '面板还没选，服务器也不许被覆盖');
      expect(app.serverAutoSync.phase, AutoSyncPhase.blocked);
      app.dispose();
    });

    test('本机 0 条、服务器有数据：只给「使用服务器数据」', () async {
      final gateway = _FakeServerGateway();
      final app = await boot(gateway);
      app.workspace.updatePrefs(
        app.prefs.copyWith(
          serverSyncEnabled: true,
          serverSyncBaseUrl: configured.baseUrl,
          serverSyncFingerprint: configured.fingerprint,
        ),
      );

      final remote = remoteOf(storeWith(savedAt: now, projects: 4));
      gateway.remote = remote;
      gateway.meta = metaOf(remote, 1);

      await app.serverAutoSyncNow();

      expect(app.pendingServerSync, isNotNull);
      expect(app.pendingServerSync!.pullOnly, isTrue);
      expect(gateway.writeCount, 0, reason: '空的不能覆盖服务器');
      app.dispose();
    });

    test('开关关着：一次网络都不发', () async {
      final gateway = _FakeServerGateway();
      final app = await bootWithServer(
        gateway,
        local: storeWith(savedAt: now, projects: 1),
      );
      app.workspace.updatePrefs(app.prefs.copyWith(serverSyncEnabled: false));

      await app.serverAutoSyncNow();

      expect(gateway.readMetaCount, 0);
      expect(gateway.readBackupCount, 0);
      expect(gateway.writeCount, 0);
      app.dispose();
    });
  });
}

class _FakeServerGateway implements ServerBackupGateway {
  RemoteBackup? remote;
  ServerMeta? meta;
  int readMetaCount = 0;
  int readBackupCount = 0;
  int writeCount = 0;
  int watchCount = 0;

  @override
  Future<RemoteBackup?> readBackup({
    required ServerBackupConfig config,
    required String token,
  }) async {
    readBackupCount += 1;
    return remote;
  }

  @override
  Future<ServerMeta?> readMeta({
    required ServerBackupConfig config,
    required String token,
  }) async {
    readMetaCount += 1;
    return meta;
  }

  @override
  Future<RemoteBackup> writeBackup({
    required ServerBackupConfig config,
    required String token,
    required List<int> bytes,
    required int baseRevision,
    required int savedAt,
    required int recordCount,
    String appVersion = '',
  }) async {
    writeCount += 1;
    final revision = (meta?.revision ?? 0) + 1;
    final written = RemoteBackup.fromBytes(
      path: '/v1/backup',
      sha: 'written-$writeCount',
      bytes: bytes,
      commitSha: '$revision',
    );
    remote = written;
    meta = ServerMeta(
      revision: revision,
      sha256: written.sha,
      size: bytes.length,
      savedAt: savedAt,
      recordCount: recordCount,
      updatedAt: savedAt,
    );
    return written;
  }

  @override
  Future<void> ping({required ServerBackupConfig config}) async {}

  @override
  Future<ServerMeta?> watchMeta({
    required ServerBackupConfig config,
    required String token,
    required int since,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    watchCount += 1;
    // 测试里不跑真实的长轮询：直接告诉控制器"这个服务端没有 watch"，
    // 让它收场（循环不会在这里空转）。
    throw const ServerWatchUnsupported();
  }
}

class _FakeServerCredentials implements ServerCredentialStore {
  const _FakeServerCredentials(this.token);

  final String token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async {}

  @override
  Future<void> clearToken() async {}
}

class _FakeGitHubCredentials implements GitHubCredentialStore {
  const _FakeGitHubCredentials(this.token);

  final String token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async {}

  @override
  Future<void> clearToken() async {}
}
