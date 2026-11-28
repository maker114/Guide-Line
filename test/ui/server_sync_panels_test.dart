import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/app/auto_sync_state.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/server_backup_config.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/core/store/github_sync.dart';
import 'package:guideline/core/store/store_diff.dart';
import 'package:guideline/platform/github_backup_client.dart';
import 'package:guideline/platform/server_backup_client.dart';
import 'package:guideline/ui/app_shell.dart';

/// 服务器那条的差异面板：控制器摆了待办，外壳要真的端出来，
/// 点「使用服务器数据」才把那份覆盖到本机。
void main() {
  late Directory tempDir;
  final int now = DateTime.now().millisecondsSinceEpoch;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_server_panels');
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

  RemoteBackup remoteOf(StoreFile store, int revision) => RemoteBackup.fromBytes(
        path: '/v1/backup',
        sha: 'sha-${store.savedAt}',
        bytes: ExportCodec.encode(store, exportedAt: store.savedAt),
        commitSha: '$revision',
      );

  testWidgets('待办摆出来：点「使用服务器数据」才覆盖本机', (tester) async {
    final gateway = _FakeServerGateway();
    final app = await AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      serverGateway: gateway,
      serverCredentials: const _FakeServerCredentials('server-token'),
      gitHubCredentials: const _FakeGitHubCredentials('ghp_token'),
    );
    expect(app.applyImport(storeWith(savedAt: now - 60000, projects: 1)), isNull);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(420, 900)),
        child: MaterialApp(home: AppShell(app: app)),
      ),
    );
    await tester.pumpAndSettle();

    final remoteStore = storeWith(savedAt: now, projects: 3);
    final remote = remoteOf(remoteStore, 2);
    gateway.remote = remote;
    gateway.meta = ServerMeta(
      revision: 2,
      sha256: remote.sha,
      size: remote.bytes.length,
      savedAt: remote.savedAt ?? 0,
      recordCount: remote.recordCount,
    );

    app.workspace.updatePrefs(
      app.prefs.copyWith(
        serverSyncEnabled: true,
        serverSyncBaseUrl: 'https://sync.example:8443',
        serverSyncFingerprint:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    );
    app.pendingServerSync = StartupSyncRequest(
      diff: diffStores(base: remoteStore, target: app.ws.buildStoreFile()),
      message: '服务器和这台设备都改过，请选择保留哪一边的数据。',
      cloudStore: remoteStore,
      localStore: app.ws.buildStoreFile(),
      cloudCommit: '2',
      localCommit: '1',
    );
    app.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('服务器和这台设备对不上'), findsOneWidget);
    expect(find.text('覆盖服务器数据'), findsOneWidget);
    expect(find.text('使用服务器数据'), findsOneWidget);

    await tester.tap(find.text('使用服务器数据'));
    await tester.pumpAndSettle();

    expect(app.projectCount, 3, reason: '点了才覆盖，本机跟着服务器那份走');
    expect(app.readServerSyncRecord()!.commitSha, '2');
    // 绿胶囊停 2 秒自己收场：把计时器跑完，别留一枚 pending timer。
    await tester.pump(
      AppController.autoSyncDoneLinger + const Duration(milliseconds: 100),
    );
    app.dispose();
  });
}

class _FakeServerGateway implements ServerBackupGateway {
  RemoteBackup? remote;
  ServerMeta? meta;

  @override
  Future<RemoteBackup?> readBackup({
    required ServerBackupConfig config,
    required String token,
  }) async =>
      remote;

  @override
  Future<ServerMeta?> readMeta({
    required ServerBackupConfig config,
    required String token,
  }) async =>
      meta;

  @override
  Future<RemoteBackup> writeBackup({
    required ServerBackupConfig config,
    required String token,
    required List<int> bytes,
    required int baseRevision,
    required int savedAt,
    required int recordCount,
    String appVersion = '',
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> ping({required ServerBackupConfig config}) async {}

  @override
  Future<ServerMeta?> watchMeta({
    required ServerBackupConfig config,
    required String token,
    required int since,
    Duration timeout = const Duration(seconds: 25),
  }) async =>
      throw const ServerWatchUnsupported();
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
