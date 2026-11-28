import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/github_backup_config.dart';
import 'package:guideline/core/models/server_backup_config.dart';
import 'package:guideline/core/store/github_sync.dart';
import 'package:guideline/platform/github_backup_client.dart';
import 'package:guideline/platform/server_backup_client.dart';
import 'package:guideline/ui/more/server_backup_page.dart';

/// 开第二条同步之前必须说清楚"会把另一条关掉"；取消就回到没开的状态。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_server_page');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('GitHub 那条开着时，开服务器先问一声；取消就保持关闭', (tester) async {
    final app = await AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      serverGateway: _FakeServerGateway(),
      serverCredentials: const _FakeServerCredentials('server-token'),
      gitHubCredentials: const _FakeGitHubCredentials('ghp_token'),
    );
    await app.saveGitHubBackupConfig(
      const GitHubBackupConfig(
        enabled: true,
        owner: 'maker114',
        repo: 'guideline-backup',
        branch: 'main',
        path: GitHubBackupConfig.defaultPath,
      ),
      'ghp_token',
    );

    await tester.pumpWidget(MaterialApp(home: ServerBackupPage(app: app)));
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('两条同步只能开一条'), findsOneWidget);
    expect(find.textContaining('GitHub 备份同步'), findsWidgets);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
      reason: '取消之后开关要退回关闭，不能停在"看着开着、其实没存"',
    );
    expect(app.prefs.serverSyncEnabled, isFalse);
    expect(app.prefs.githubBackupEnabled, isTrue);
    app.dispose();
  });
}

class _FakeServerGateway implements ServerBackupGateway {
  @override
  Future<RemoteBackup?> readBackup({
    required ServerBackupConfig config,
    required String token,
  }) async =>
      null;

  @override
  Future<ServerMeta?> readMeta({
    required ServerBackupConfig config,
    required String token,
  }) async =>
      null;

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
