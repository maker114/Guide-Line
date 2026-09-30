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
import 'package:guideline/platform/data_directory.dart';
import 'package:guideline/platform/github_backup_client.dart';
import 'package:guideline/ui/common/commit_lcd.dart';
import 'package:guideline/ui/more/github_backup_page.dart';

/// GitHub 备份同步是**正式功能**，这一页守住四件"不许悄悄发生"的事：
///   · **总开关关着就一份都不许连网**（含推送、拉取）。灰按钮挡不住无障碍焦点
///     与热键重入，所以这里既验界面置灰、也验控制器那一层真的会拒绝；
///   · **未配置也能进页** —— 进不来就没法配置，这一页不能要求"先配好再打开"；
///   · **拉取前必须先预览**：条数与时间摆在确认框里，没点确认就不许覆盖本地；
///   · **提交码要摆到明面上**：双端对版本靠的是提交码（内容码只答"内容一不一样"），
///     记账里没有它时写「未知」，不许当成"两边不一致"。
void main() {
  late Directory tempDir;

  const int t1 = 1788652800000; // 2026-09-23 08:00 UTC

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_github_page');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Project project(String id) => Project(
        id: id,
        title: '指南线',
        purpose: '目的',
        implementation: '实现',
        date: '2026-09-23',
        status: NodeStatus.pending,
        archived: false,
        parentProjectId: null,
        order: 1000,
        completedAt: null,
        createdAt: t1,
        updatedAt: t1,
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

  /// 远程那一份：走与真实推送完全相同的编码，免得测试验的是"我以为的形状"。
  RemoteBackup remoteOf(StoreFile store, {String sha = 'sha-remote'}) =>
      RemoteBackup.fromBytes(
        path: GitHubBackupConfig.defaultPath,
        sha: sha,
        bytes: ExportCodec.encode(store, exportedAt: store.savedAt),
      );

  Future<AppController> boot(_FakeGateway gateway, _FakeCredentials credentials) =>
      AppController.bootstrap(
        dataDirectoryOverride: tempDir,
        gitHubGateway: gateway,
        gitHubCredentials: credentials,
      );

  Future<void> openPage(WidgetTester tester, AppController app) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: GitHubBackupPage(app: app)));
    await tester.pumpAndSettle();
  }

  /// 推进几帧，**不用 `pumpAndSettle`**。
  ///
  /// 这一页在 `_busy` 期间有一条 `LinearProgressIndicator`：它是不定长动画，
  /// 会一直排帧，`pumpAndSettle` 永远等不到"没有待处理帧"那一刻而超时。
  /// 所以这里改成明确推几帧 —— 假 gateway 是同步返回的，几帧足够让
  /// 「异步读远程 → 弹确认框」这条链走完。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> tapAction(WidgetTester tester, String title) async {
    final finder = find.ancestor(
      of: find.text(title),
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await settle(tester);
  }

  const GitHubBackupConfig configured = GitHubBackupConfig(
    enabled: true,
    owner: 'maker114',
    repo: 'guideline-backup',
    branch: 'main',
    path: GitHubBackupConfig.defaultPath,
  );

  group('总开关关着', () {
    testWidgets('推送与拉取都点不动，测试连接仍可用', (tester) async {
      final gateway = _FakeGateway();
      final credentials = _FakeCredentials('ghp_token');
      final app = await boot(gateway, credentials);
      await app.saveGitHubBackupConfig(
        configured.copyWith(enabled: false),
        'ghp_token',
      );

      await openPage(tester, app);

      final push = tester.widget<ListTile>(
        find.ancestor(of: find.text('推送到 GitHub'), matching: find.byType(ListTile)),
      );
      final pull = tester.widget<ListTile>(
        find.ancestor(of: find.text('从 GitHub 拉取'), matching: find.byType(ListTile)),
      );
      final test = tester.widget<ListTile>(
        find.ancestor(of: find.text('测试连接'), matching: find.byType(ListTile)),
      );
      expect(push.onTap, isNull);
      expect(pull.onTap, isNull);
      expect(test.onTap, isNotNull, reason: '测试连接是只读的，关着开关也该能验配置');
      expect(find.textContaining('开关关着'), findsOneWidget);

      await tapAction(tester, '推送到 GitHub');
      await tapAction(tester, '从 GitHub 拉取');
      expect(gateway.readCount, 0, reason: '开关关着就一次网络都不该发出去');
      expect(gateway.writeCount, 0);
    });

    testWidgets('界面被绕过时控制器也拒绝（灰按钮挡不住热键重入）', (tester) async {
      final gateway = _FakeGateway();
      final app = await boot(gateway, _FakeCredentials('ghp_token'));

      final off = configured.copyWith(enabled: false);
      final pushed = await app.pushGitHubBackup(off, 'ghp_token');
      expect(pushed.ok, isFalse);
      expect(pushed.message, contains('开关还关着'));

      final pulled = await app.previewGitHubPull(off, 'ghp_token');
      expect(pulled.remote, isNull);
      expect(pulled.error, contains('开关还关着'));

      expect(gateway.readCount, 0);
      expect(gateway.writeCount, 0);
    });
  });

  group('未配置也能进页', () {
    testWidgets('一进来是空的默认值，不是错误页', (tester) async {
      final app = await boot(_FakeGateway(), _FakeCredentials(null));

      await openPage(tester, app);

      expect(find.text('启用 GitHub 备份同步'), findsOneWidget);
      expect(find.text('推送到 GitHub'), findsOneWidget);
      expect(find.text('从 GitHub 拉取'), findsOneWidget);
      // 五个输入框都在（所有者 / 仓库名 / 分支 / 远程文件路径 / Token）
      expect(find.byType(TextField), findsNWidgets(5));
      expect(find.text('还没填仓库所有者'), findsNothing, reason: '未配置不等于报错');
      expect(tester.takeException(), isNull);
    });
  });

  group('测试连接', () {
    testWidgets('仓库 / 权限不对：当场报失败，不再说成「远程还没有备份」', (tester) async {
      final gateway = _FakeGateway()..repositoryMissing = true;
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');

      await openPage(tester, app);
      await tapAction(tester, '测试连接');

      // 旧写法这里会说「连上了，但远程还没有这份备份」—— owner 拼错也长这样，
      // 等于把配置错误报成了正常状态（ADR-090）。
      expect(find.textContaining('连接失败'), findsOneWidget);
      expect(find.textContaining('连通成功'), findsNothing);
    });

    testWidgets('仓库在、只是还没推过：说清仓库在哪，不让人以为配错了', (tester) async {
      final gateway = _FakeGateway();
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');

      await openPage(tester, app);
      await tapAction(tester, '测试连接');

      expect(find.textContaining('连通成功'), findsOneWidget);
      expect(find.textContaining('maker114/guideline-backup'), findsOneWidget);
      expect(find.textContaining('这个路径还没有备份'), findsOneWidget);
    });
  });

  group('拉取要先预览再落盘', () {
    testWidgets('确认框里摆出远程的条数、时间与提交码；取消就一点都不动', (tester) async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 3)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final credentials = _FakeCredentials('ghp_token');
      final app = await boot(gateway, credentials);
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      expect(app.applyImport(storeWith(savedAt: t1 + 60000, projects: 1)), isNull);
      // 注意断言的是**盘上**那句 savedAt：`ws.buildStoreFile()` 每次调用都现取
      // `now()`，拿它当"有没有被改过"的凭据是比不出来的。
      final before = app.storage.readStoreSavedAt();
      expect(before, isNotNull);
      expect(app.projectCount, 1);

      await openPage(tester, app);
      await tapAction(tester, '从 GitHub 拉取');

      expect(find.text('用远程那份覆盖这台手机'), findsOneWidget);
      expect(find.textContaining('项目 3'), findsOneWidget, reason: '远程那边有多少要说清');
      expect(find.textContaining(formatStamp(t1)), findsOneWidget, reason: '远程那份的时间要给');
      expect(
        find.textContaining('这台手机（会被覆盖）· 项目 1'),
        findsOneWidget,
        reason: '现在这台上有什么要说清 —— 否则用户不知道会丢掉几条',
      );
      expect(
        find.textContaining('远程提交：abc1234'),
        findsOneWidget,
        reason: '双端对版本靠提交码，预览框里就得给出来',
      );

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(gateway.writeCount, 0);
      expect(app.projectCount, 1, reason: '没点确认就不许覆盖本地');
      expect(app.storage.readStoreSavedAt(), before, reason: '取消之后盘上一个字都不该变');
      expect(app.readGitHubSyncRecord(), isNull, reason: '没落盘就不该有记账');
    });

    testWidgets('远程 0 条时直接给结论，连确认框都不弹', (tester) async {
      final gateway = _FakeGateway(remote: remoteOf(StoreFile.empty()));
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');

      await openPage(tester, app);
      await tapAction(tester, '从 GitHub 拉取');

      expect(find.text('用远程那份覆盖这台手机'), findsNothing);
      expect(find.textContaining('0 条不算可用备份'), findsOneWidget);
    });

    testWidgets('拉取之后写记账，页面上能看到上次同步时间与两个码', (tester) async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 2)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');

      await openPage(tester, app);
      await tapAction(tester, '从 GitHub 拉取');
      await tester.tap(find.text('拉取并覆盖'));
      await tester.pumpAndSettle();

      expect(app.projectCount, 2);
      final record = app.readGitHubSyncRecord();
      expect(record, isNotNull);
      expect(record!.recordCount, 2);
      expect(record.remoteSha, 'sha-remote');
      expect(
        record.commitSha,
        'abc1234def5678',
        reason: '提交码要落进记账，重启后才对得出"是不是同一次上传"',
      );
      expect(find.textContaining('上次同步：'), findsOneWidget);
      expect(
        find.textContaining('提交 abc1234 · 内容码 sha-rem'),
        // 两处都会摆出这两个码：页面上「上次同步」那一行，以及拉取结果框。
        findsNWidgets(2),
        reason: '两个码并列摆出来，但要说清各自答的是什么',
      );
    });
  });

  group('推送', () {
    testWidgets('记账里带提交码，结果里两个码都摆出来，提交说明带 App 版本号', (tester) async {
      final gateway = _FakeGateway();
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      expect(app.applyImport(storeWith(savedAt: t1, projects: 2)), isNull);

      final pushed = await app.pushGitHubBackup(configured, 'ghp_token');

      expect(pushed.ok, isTrue, reason: pushed.message);
      expect(pushed.message, contains('提交 commit-'));
      expect(pushed.message, contains('内容码 sha-wri'));
      final record = app.readGitHubSyncRecord();
      expect(record, isNotNull);
      expect(record!.commitSha, 'commit-written', reason: '这次推送的提交码要记住');
      expect(record.remoteSha, 'sha-written');
      expect(
        gateway.lastMessage,
        contains(AppInfo.versionLabel),
        reason: '提交说明里带版本号，GitHub 的提交列表里才看得出是哪一版推的',
      );
    });
  });

  group('页顶那台提交号点阵屏', () {
    testWidgets('一进来就摆在最上面；还没有记账时全暗、不写假文字', (tester) async {
      final app = await boot(_FakeGateway(), _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');

      await openPage(tester, app);

      final lcd = find.byType(CommitLcd);
      expect(lcd, findsOneWidget, reason: '当前提交号要单开一框，摆在标题栏下面第一个位置');
      expect(
        tester.getTopLeft(lcd).dy,
        lessThan(tester.getTopLeft(find.text('启用 GitHub 备份同步')).dy),
        reason: '它在最上面，不是埋在「同步」那一段里',
      );
      expect(find.text('未知'), findsNothing, reason: '没有提交号时全暗，不给假文字');
      expect(app.readGitHubSyncRecord(), isNull);
    });

    testWidgets('同步过一次之后：屏上那串就是记账里存的提交号', (tester) async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 2)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      final handle = tester.ensureSemantics();

      await openPage(tester, app);
      await tapAction(tester, '从 GitHub 拉取');
      await tester.tap(find.text('拉取并覆盖'));
      await tester.pumpAndSettle();

      expect(app.readGitHubSyncRecord()!.commitSha, 'abc1234def5678');
      expect(
        find.bySemanticsLabel('当前提交号 abc1234def5678'),
        findsOneWidget,
        reason: '点阵是画出来的，读屏只能靠语义标签；标签要给完整提交号',
      );
      handle.dispose();
    });
  });
}

class _FakeGateway implements GitHubBackupGateway {
  _FakeGateway({this.remote, this.commit});

  RemoteBackup? remote;
  RemoteCommit? commit;
  int readCount = 0;
  int writeCount = 0;

  /// 最后一次推送用的提交说明（验"App 版本号跟着一起上去了"）。
  String lastMessage = '';

  @override
  Future<RemoteBackup?> readBackup({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    readCount += 1;
    return remote;
  }

  @override
  Future<RemoteCommit?> latestCommit({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    readCount += 1;
    return commit;
  }

  /// 「测试连接」在 404 之后要问的那一句（ADR-090）。
  RemoteRepository repository = const RemoteRepository(
    fullName: 'maker114/guideline-backup',
    isPrivate: true,
    defaultBranch: 'main',
  );

  /// 设成 true 就让 [describeRepository] 抛"仓库不存在" ——
  /// 用来验"owner 拼错时当场报失败，而不是报成远程还没有备份"。
  bool repositoryMissing = false;

  @override
  Future<RemoteRepository> describeRepository({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    readCount += 1;
    if (repositoryMissing) {
      throw const GitHubBackupException(
        '仓库或分支不存在（404）：核对所有者、仓库名、分支名是否正确',
      );
    }
    return repository;
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
    // 真 gateway 会把 PUT 返回里的提交码原样带回来；这里也照做，
    // 否则"记账里有没有提交码"这条就验不到了。
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
