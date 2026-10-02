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
      expect(pushed.message, contains('开关尚未启用'));

      final pulled = await app.previewGitHubPull(off, 'ghp_token');
      expect(pulled.remote, isNull);
      expect(pulled.error, contains('开关尚未启用'));

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

      expect(find.text('用远程备份覆盖这台手机'), findsOneWidget);
      expect(find.textContaining('项目 3'), findsOneWidget, reason: '远程那边有多少要说清');
      expect(find.textContaining(formatStamp(t1)), findsOneWidget, reason: '远程那份的时间要给');
      expect(
        find.textContaining('这台手机 · 会被覆盖 · 项目 1'),
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

      expect(find.text('用远程备份覆盖这台手机'), findsNothing);
      expect(find.textContaining('远程备份是 0 条记录，不算可用备份'), findsOneWidget);
    });

    testWidgets('两边内容一样：弹一句提醒、不拉回，还能选「仍然强制拉回」', (tester) async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 2)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      expect(app.applyImport(storeWith(savedAt: t1 + 60000, projects: 2)), isNull);
      final before = app.storage.readStoreSavedAt();

      await openPage(tester, app);
      await tapAction(tester, '从 GitHub 拉取');

      // 内容一条不差：不摆差异面板（没什么可看的），只提醒一句。
      expect(find.text('云端和这台手机是同一份'), findsOneWidget);
      expect(find.textContaining('一条不差'), findsOneWidget);
      expect(find.text('用远程备份覆盖这台手机'), findsNothing);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(app.storage.readStoreSavedAt(), before, reason: '取消之后盘上一个字都不该变');
      expect(app.readGitHubSyncRecord(), isNull, reason: '没拉回就不该有记账');
      expect(find.textContaining('内容相同，没有拉回'), findsOneWidget, reason: '要说清为什么没动');
    });

    testWidgets('两边内容一样时选「仍然强制拉回」：真的覆盖，并写上记账', (tester) async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 2)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      expect(app.applyImport(storeWith(savedAt: t1 + 60000, projects: 2)), isNull);

      await openPage(tester, app);
      await tapAction(tester, '从 GitHub 拉取');
      await tester.tap(find.text('仍然强制拉回'));
      await tester.pumpAndSettle();

      final record = app.readGitHubSyncRecord();
      expect(record, isNotNull, reason: '强制拉回也要记账，否则下次还会当成"没同步过"');
      expect(record!.commitSha, 'abc1234def5678');
    });

    testWidgets('拉取之后写记账，页面上能看到上次同步时间与提交码', (tester) async {
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
      // 2026-10-02 改（用户第二次问"我该相信哪个"）：
      // 原来这里断言页面上摆出**两个**码（`提交 abc1234 · 内容码 sha-rem`），
      // 而点阵屏上还摆着**另一个**码 —— 一个页面三个码、两种类型，
      // 用户没法判断该信哪个。现在文案里只留**提交码**这一个，
      // 内容指纹只在点阵屏上出现（那两排才是同一种、可以比的东西）。
      expect(
        find.textContaining('那一次上传的提交码：abc1234'),
        findsNWidgets(2),
        // 两处都会摆：页面上「上次同步」那一行，以及拉取结果框。
        reason: '提交码是"传的是哪一次"的凭证，必须让用户看见',
      );
      expect(
        find.textContaining('内容码'),
        findsNothing,
        reason: '文案里不许再出现第二个"码" —— 一个页面只留一种可比的码',
      );
    });
  });

  group('推送', () {
    testWidgets('点一下就推：不再摆确认框，也不再摆差异面板', (tester) async {
      // 云端一条、本机两条：内容真的不同 —— 老写法会先弹差异面板等确认。
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 1)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      expect(app.applyImport(storeWith(savedAt: t1 + 60000, projects: 2)), isNull);

      await openPage(tester, app);
      await tapAction(tester, '推送到 GitHub');

      expect(gateway.writeCount, 1, reason: '点一下就该真的推上去（用户口径：默认强制推送）');
      expect(find.text('推送'), findsNothing, reason: '不该再有确认按钮');
      expect(find.text('云端 · 会被覆盖'), findsNothing, reason: '不该再摆差异面板');
      expect(find.textContaining('已推送'), findsOneWidget, reason: '收据还是要给');
    });

    testWidgets('内容一字不差：一次都不提交，直接说清原因', (tester) async {
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 2)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      // 同一份内容、只是本机的时间戳更新 —— 正是"刚拉回来又被推一次"的那一幕。
      expect(app.applyImport(storeWith(savedAt: t1 + 60000, projects: 2)), isNull);

      await openPage(tester, app);
      await tapAction(tester, '推送到 GitHub');

      expect(gateway.writeCount, 0, reason: '内容一样就不该再添一次无意义的提交');
      expect(find.textContaining('同一份'), findsOneWidget, reason: '说清是同一份，不必推送');
    });

    testWidgets('记账里带提交码，结果里只摆提交码，提交说明带 App 版本号', (tester) async {
      final gateway = _FakeGateway();
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      expect(app.applyImport(storeWith(savedAt: t1, projects: 2)), isNull);

      final pushed = await app.pushGitHubBackup(configured, 'ghp_token');

      expect(pushed.ok, isTrue, reason: pushed.message);
      // 2026-10-02 改：结果框原来也摆"提交 … · 内容码 …"两个码。
      // 用户第二次问"我该相信哪个"就是这个造成的 —— 现在结果框只摆提交码。
      expect(pushed.message, contains('那一次上传的提交码：commit-'));
      expect(
        pushed.message,
        isNot(contains('内容码')),
        reason: '一个页面上只留一种可比的码；blob sha 不该出现在给用户看的文案里',
      );
      final record = app.readGitHubSyncRecord();
      expect(record, isNotNull);
      expect(record!.commitSha, 'commit-written', reason: '这次推送的提交码要记住');
      // 记账里**仍然**要存 blob sha —— 它是"内容一不一样"的基线，只是不给用户看。
      expect(
        record.remoteSha,
        'sha-written',
        reason: '记账内部要用它做下次覆盖的基线，别跟着文案一起删了',
      );
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

    testWidgets('同步过一次之后：两排都是本机指纹，且只念 7 位', (tester) async {
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
      // 2026-10-02 改（用户**第二次**指出"点阵屏显示的提交码和拉取下面那个不一样，
      // 我该相信哪个"）：两排都摆**本机内容指纹**这个方向是对的，
      // 但上一版的标识（"云端 / 本机"）会让人以为上排是云端的码 —— 于是又猜错一次。
      // 现在标识改成**"上传时 / 本机现在"**：两排都是本机指纹，差的是**时刻**。
      expect(
        find.bySemanticsLabel(RegExp(r'^上一次上传时的内容指纹 [0-9a-f]{7}$')),
        findsOneWidget,
        reason: '上排 = 上次成功上传时本机那一份的指纹（记账里的 localSha）',
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^本机现在的内容指纹 [0-9a-f]{7}$')),
        findsOneWidget,
        reason: '下排 = 此刻本机这一份的指纹，现算的',
      );
      // 文案里不许再出现第二个"码"（那是"我该信哪个"的根源）。
      expect(
        find.textContaining('内容码'),
        findsNothing,
        reason: '一个页面只留一种可比的码；blob sha 那种不该出现在文案里',
      );
      // 只念 7 位：完整 40 位 sha 递给读屏软件是 2.3.0 之前那个缺陷，
      // 这条守卫留着别删。
      expect(
        find.bySemanticsLabel(RegExp(r'\w{8,}')),
        findsNothing,
        reason: '语义句里出现 8 位以上的连续码，就说明有人把完整 sha 递进来了',
      );
      // 刚拉完，两排应当**相等**（本机刚被云端覆盖过，指纹与记账一致）。
      final labels = tester
          .widgetList<Semantics>(find.descendant(
            of: find.byType(CommitLcd),
            matching: find.byType(Semantics),
          ))
          .map((s) => s.properties.label ?? '')
          .where((l) => l.contains('指纹'))
          .toList();
      expect(labels.length, 2, reason: '正好两排指纹');
      final codes = labels
          .map((l) => RegExp(r'[0-9a-f]{7}').stringMatch(l))
          .toList();
      expect(
        codes[0],
        codes[1],
        reason: '刚同步完，两排该相等 —— 不等就说明记账的 localSha 写错了',
      );
      handle.dispose();
    });

    testWidgets('两排不一样时，屏下面那句直接给结论，不让用户自己比码', (tester) async {
      // 2026-10-02 用户**第二次**问"我该相信哪个"之后加的。
      //
      // 第一次（2.3.0）是"上排云端提交码 / 下排本机指纹"，两个码不可比；
      // 我改成"两排都是本机指纹"，**但把 git 提交码从屏上赶走、留在下面那行**，
      // 于是同一个页面上仍是两个不同来源的码，用户又猜一次。
      //
      // 这条守的是最终口径：**屏幕上只摆一种可比的码**（本机指纹），
      // 而"一样 / 不一样"这个结论由文案直说 —— 用户不该被迫去比两串十六进制。
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

      // 拉完之后本机与记账一致 → 该说"没有新东西要传"。
      expect(
        find.textContaining('两排一样'),
        findsOneWidget,
        reason: '结论要写在屏下面那句里 —— 用户不该被迫去比两串十六进制',
      );
      expect(
        find.textContaining('内容码'),
        findsNothing,
        reason: '屏幕上只留一种可比的码；blob sha 那种不该出现',
      );
      // 反过来的那一面（"两排不一样 ⇒ 还没传上去"）没在这里硬测：
      // 拉完之后要再造出"本机比上传时新"的状态，得绕开这一页的只读约束去改数据，
      // 那样测的是夹具而不是这一页。这条口径由 `_commitScreenNote` 的三条分支
      // 直接表达，改的时候看得见 —— 硬凑一个夹具反而更脆。
    });

    // ---------------------------------------------------------- 检查更新（2026-10-02）

    testWidgets('检查更新：两边一样时直说"没有要更新的东西"，且一个字节都不写', (tester) async {
      // 这一组钉的是「检查更新」的**只读**性质。它是全页唯一"看了不改"的入口，
      // 所以两件事都要证：① 它真的读了云端；② 它**没写任何东西**
      // （没写本机、没写记账、没写云端）。
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 2)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      await openPage(tester, app);

      // 先拉一次，让本机与云端成为同一份（否则下面会走"有差别"那一支）。
      await tapAction(tester, '从 GitHub 拉取');
      await tester.tap(find.text('拉取并覆盖'));
      await tester.pumpAndSettle();

      final writesBefore = gateway.writeCount;
      final recordBefore = app.readGitHubSyncRecord()!.syncedAt;
      final readsBefore = gateway.readCount;

      await tapAction(tester, '检查更新');
      await tester.pumpAndSettle();

      expect(
        gateway.readCount,
        greaterThan(readsBefore),
        reason: '它必须真的去读一次云端，不能只看本地记账就说"一样"',
      );
      expect(gateway.writeCount, writesBefore, reason: '检查更新**绝不许**写云端');
      expect(
        app.readGitHubSyncRecord()!.syncedAt,
        recordBefore,
        reason: '记账不该被动过 —— 检查不是同步',
      );
      expect(
        find.textContaining('没有要更新的东西'),
        findsOneWidget,
        reason: '两边一样时要说清"没什么可更新的"，而不是摆一个空面板',
      );
    });

    testWidgets('检查更新：有差别时摆出逐条差异，但不给"覆盖"按钮', (tester) async {
      // 云端与本地内容不同 → 摆面板；而**面板上不许有会改数据的按钮**，
      // 否则这个"只读入口"就变成了一个伪装成只读的覆盖入口。
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 5)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await app.saveGitHubBackupConfig(configured, 'ghp_token');
      await openPage(tester, app);

      await tapAction(tester, '检查更新');
      // `pumpAndSettle` 会超时：差异面板是**一直开着**的（等用户点"知道了"），
      // 只要它开着就有持续的重建，settle 永远等不到。本文件其它面板用例
      // 同样只用一次 `pump()`。
      await tester.pump();

      expect(find.text('云端与这台手机的差别'), findsOneWidget);
      expect(
        find.text('知道了'),
        findsOneWidget,
        reason: '只读面板的出口是"知道了"',
      );
      expect(
        find.text('拉取并覆盖'),
        findsNothing,
        reason: '只读入口不许出现会覆盖本机的按钮',
      );
    });

    testWidgets('检查更新在开关关着时也能用（只读入口不依赖开关）', (tester) async {
      // 推送 / 拉取在开关关着时是禁用的（它们会写）。检查更新只读，不该跟着禁用 ——
      // 否则用户想"就看看云端有什么"也得先把自动同步打开。
      //
      // 判据看的是 `onTap` 是不是 null：`_ActionTile` 禁用就是把手势摘掉
      // （`ListTile.onTap: null`），**没有** `enabled` 这个参数。
      final gateway = _FakeGateway(
        remote: remoteOf(storeWith(savedAt: t1, projects: 2)),
        commit: RemoteCommit(sha: 'abc1234def5678'),
      );
      final app = await boot(gateway, _FakeCredentials('ghp_token'));
      await openPage(tester, app);

      ListTile tileOf(String title) => tester.widget<ListTile>(
        find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
      );

      expect(tileOf('检查更新').onTap, isNotNull, reason: '只读入口不该被开关禁用');
      expect(tileOf('测试连接').onTap, isNotNull, reason: '测试连接也是只读的');
      expect(tileOf('推送到 GitHub').onTap, isNull, reason: '开关关着，推送要禁用');
      expect(tileOf('从 GitHub 拉取').onTap, isNull, reason: '开关关着，拉取要禁用');
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
        '仓库或分支不存在，HTTP 404：核对所有者、仓库名、分支名是否正确',
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
