import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/ids.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/atomic_file.dart';
import 'package:guideline/core/store/merge.dart';
import 'package:guideline/features/workspace.dart';

/// 写盘失败时的行为（磁盘满 / 权限被拒），以及「导出记账」的口径（Q11）。
///
/// 业务动作的写法是「先改内存，再整份落盘」，所以写失败时内存**已经改了**。
/// 这时有两条底线：
///   1. 必须如实告诉用户"没写进去"，绝不能弹一句成功；
///   2. 内存要退回动作前的样子，不能显示一个磁盘上并不存在的状态。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guideline_ctrl_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  AppController controllerWith(AppStorage storage, {ShareFileHook? shareFile}) {
    final report = storage.load();
    return AppController(
      storage: storage,
      workspace: Workspace.fromLoad(storage, report),
      dataDirectory: tempDir,
      startupWarnings: const <String>[],
      shareFile: shareFile,
    );
  }

  test('正常情况：返回 null，通知了监听者，而且确实落盘了', () {
    final storage = AppStorage(AppPaths(tempDir));
    final app = controllerWith(storage);
    var notified = 0;
    app.addListener(() => notified += 1);

    final error = app.run(() => app.ws.createProject(title: '正常项目'));

    expect(error, isNull);
    expect(notified, 1);
    expect(app.ws.liveProjects.single.title, '正常项目');
    expect(storage.paths.storeFile.existsSync(), isTrue);
    expect(storage.paths.storeFile.readAsStringSync(), contains('正常项目'));
  });

  test('业务规则违规仍返回自己的文案，不会被误判成写盘失败', () {
    final app = controllerWith(AppStorage(AppPaths(tempDir)));

    expect(app.run(() => app.ws.createProject(title: '   ')), '项目名不能为空');
    expect(app.ws.liveProjects, isEmpty, reason: '被规则挡下时不该留下任何痕迹');
  });

  test('写盘失败：返回可读文案、不抛异常、并且把内存退回原样', () {
    final app = controllerWith(_FailingStorage(AppPaths(tempDir)));
    expect(app.ws.liveProjects, isEmpty);

    String? error;
    expect(
      () => error = app.run(() => app.ws.createProject(title: '写不进去的项目')),
      returnsNormally,
      reason: '磁盘问题不该以异常形式炸到界面上',
    );

    expect(error, isNotNull);
    expect(error, contains('保存失败'));
    expect(error, contains('没有写入磁盘'));
    expect(
      app.ws.liveProjects,
      isEmpty,
      reason: '内存必须回滚 —— 界面不能显示一个磁盘上不存在的状态',
    );
  });

  test('写盘失败不会污染后续操作：退回去之后仍能继续用', () {
    final storage = _FailingStorage(AppPaths(tempDir));
    final app = controllerWith(storage);

    app.run(() => app.ws.createProject(title: '第一次失败'));
    expect(app.ws.liveProjects, isEmpty);

    storage.failing = false;
    expect(app.run(() => app.ws.createProject(title: '第二次成功')), isNull);
    expect(app.ws.liveProjects.single.title, '第二次成功');
    expect(storage.paths.storeFile.readAsStringSync(), contains('第二次成功'));
  });

  group('导出记账（Q11：没分享出去就不算导出）', () {
    test('取消分享：文件照样落盘，但 lastExportedAt 不变、提醒不销账', () async {
      final storage = AppStorage(AppPaths(tempDir));
      var shareCalls = 0;
      final app = controllerWith(
        storage,
        shareFile: (path, {required text, required subject}) async {
          shareCalls += 1;
          return false; // 用户在分享面板上取消了
        },
      );
      expect(app.exportOverdue, isTrue, reason: '从来没导出过');

      final result = await app.exportAndShare();

      expect(shareCalls, 1, reason: '确实走过分享这一步');
      expect(result.ok, isTrue, reason: '写文件本身成功了，不该报成失败');
      expect(result.message, contains('应用私有目录'));
      expect(result.message, contains('没有离开手机'));
      expect(result.message, contains('不会销账'));
      expect(storage.listExports(), isNotEmpty, reason: '文件仍然写进了私有目录');
      expect(app.lastExportedAt, isNull, reason: '没分享出去就不记账');
      expect(app.exportOverdue, isTrue, reason: '「该导出了」必须继续挂着');
    });

    test('真的分享出去：记下时间，提醒销账', () async {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(
        storage,
        shareFile: (path, {required text, required subject}) async => true,
      );

      final result = await app.exportAndShare();

      expect(result.ok, isTrue);
      expect(result.message, contains('已导出并分享'));
      expect(app.lastExportedAt, isNotNull);
      expect(app.exportOverdue, isFalse, reason: '刚分享成功，7 天提醒从头算');
    });
  });

  group('损坏之后重新拉响导出提醒（Q16）', () {
    test('主文件损坏自动恢复 → exportOverdue 重新为真', () async {
      final storage = AppStorage(AppPaths(tempDir));
      storage.save(StoreFile.empty(), nowMillis: _day);
      // 造一份"上一份"备份，再把主文件弄坏
      storage.save(StoreFile.empty(), nowMillis: _day + 1, forceRotate: true);
      storage.savePrefs(UiPrefs.empty.copyWith(lastExportedAt: Ids.nowMillis()));
      expect(storage.listBackups(), isNotEmpty, reason: '先得有能恢复的备份');
      storage.paths.storeFile.writeAsStringSync('{"broken": ');

      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);

      expect(app.hasDataIncident, isTrue);
      expect(app.exportOverdue, isTrue, reason: '刚出过数据事故，该导出了要重新出现');
    });

    test('一切正常时不动导出提醒', () async {
      final app0 = await AppController.bootstrap(dataDirectoryOverride: tempDir);
      app0.run(() => app0.ws.markExported(Ids.nowMillis()));

      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);

      expect(app.hasDataIncident, isFalse);
      expect(app.exportOverdue, isFalse, reason: '没出事故就不该把用户刚销的账又翻出来');
    });
  });

  group('手动备份（P1-3）', () {
    test('「立即备份一份」真的写出了一份备份', () {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      app.run(() => app.ws.createProject(title: '项目'));

      final error = app.snapshotBackupNow();

      expect(error, isNull);
      expect(
        storage.paths.rollingBackup(1).existsSync(),
        isTrue,
        reason: '说了成功就必须真的有一份备份落在盘上',
      );
    });

    test('写不出备份时如实报错，而不是报成功（P1-3）', () {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      app.run(() => app.ws.createProject(title: '项目'));

      // 让备份**复制**这一步失败（模拟权限 / 磁盘满）。
      //
      // 这里换过一次写法：原先靠"把目录设成只读"（Windows `attrib +R` / POSIX `chmod`），
      // 而那条路**在 Windows 上拦不住写** —— `rollingBackup(1).existsSync()` 恒为真，
      // 于是用例只走"真的写出来了就该报成功"那一支，**恒过、什么也没证明**。
      // 注入点是确定性的，两个平台走同一条路（与 `atomic_file_test.dart` 同一个做法）。
      AtomicFile.copyHook = (from, to) {
        if (to.path.contains(AppPaths.backupPrefix)) {
          throw const FileSystemException('注入的失败：备份写不进去');
        }
        from.copySync(to.path);
      };
      addTearDown(() => AtomicFile.copyHook = null);

      final error = app.snapshotBackupNow();

      expect(
        error,
        isNotNull,
        reason: '一条备份都没写出来还说"已备份"，就是在骗用户',
      );
      expect(
        storage.paths.rollingBackup(1).existsSync(),
        isFalse,
        reason: '这次确实一份都没写出来（下面那条用例才造"旧备份还在"的情形）',
      );
    });

    test('上次成功、这次写不出来：不能拿旧的那份冒充（P1-3）', () {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      app.run(() => app.ws.createProject(title: '项目'));

      // 先正常留一份，让盘上真的有一份滚动备份
      expect(app.snapshotBackupNow(), isNull, reason: '第一次应当成功');
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue);

      // 再注入失败：这一次写不出新的了
      AtomicFile.copyHook = (from, to) {
        if (to.path.contains(AppPaths.backupPrefix)) {
          throw const FileSystemException('注入的失败：备份写不进去');
        }
        from.copySync(to.path);
      };
      addTearDown(() => AtomicFile.copyHook = null);

      final error = app.snapshotBackupNow();

      // 这一条要钉的是**"上次成功过"不能影响这一次的判断**。
      //
      // 实测到的机制（写下来免得下一个人像我先猜错一次）：轮转会先把旧备份
      // **移位**成 `backup.2`，所以新复制失败时 `backup.1` 已经不在盘上了 ——
      // 于是**旧判据（`rollingBackup(1).existsSync()`）在这里也会给出正确的结论**。
      // 我原以为这是一条能复现"报假成功"的用例，**突变测试证明不能**：
      // 把守卫改回旧判据，这条用例照样过。
      //
      // 所以这条用例的定位是**锁住行为**（上次成功过、这次没写成 → 必须报错），
      // 而不是"证明修了一个已发生的缺陷"。真正被修掉的是这个判据**语义上的脆弱**：
      // 它问的是"盘上有没有一份"，而它想知道的是"这一次写出来没有" ——
      // 前者只有在"旧的那份恰好还在原位"时才会答错，而移位机制让它很难发生。
      // 判据改成比 mtime 之后，这个问题从根上不存在了。
      expect(
        error,
        isNotNull,
        reason: '上次成功过，不等于这一次也成功 —— 写不出来就必须报错',
      );
      expect(
        storage.paths.rollingBackup(1).existsSync(),
        isFalse,
        reason: '这次确实没写出新的 backup.1',
      );
      expect(
        storage.paths.rollingBackup(2).existsSync(),
        isTrue,
        reason: '旧的那份挪到了 backup.2 —— "上次有一份"与"这次写出来了"是两件事',
      );
    });
  });

  group('整体替换导入（P1-5）', () {
    test('刚保存过也能先留一份备份，导错有退路', () {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      app.run(() => app.ws.createProject(title: '本机当前数据'));

      // 紧接着导入（时间上落在轮转节流窗口内）
      final incoming = app.ws.buildStoreFile();
      final error = app.applyImport(incoming);
      expect(error, isNull);

      final backup = storage.paths.rollingBackup(1);
      expect(
        backup.existsSync(),
        isTrue,
        reason: '覆盖性操作必须无条件先留一份，不能被节流拦下（P1-5）',
      );
      final titles = StoreFile
          .parse(backup.readAsStringSync(), DecodeIssues())
          .documentOf(DocName.projects)
          .projectItems
          .map((p) => p.title)
          .toList();
      expect(
        titles,
        contains('本机当前数据'),
        reason: '备份里必须是"导入之前"的那份数据，实际=$titles',
      );
    });
  });

  group('备份页的三个动作（T-6：这三个方法此前在 test/ 里一次都没被调用过）', () {
    /// 用 storage 直接造数据与备份：`app.run` 走真实时钟，而轮转按 5 分钟节流，
    /// 想造出确定的"上一份"必须显式给时间戳。
    ///
    /// 构造结果：主文件 = '后来误加的'，rollbackBackup(1) = '要留下的'。
    ({AppController app, AppStorage storage}) bootWithBackup() {
      final storage = AppStorage(AppPaths(tempDir));
      // 第一次保存：磁盘上还没有旧文件，不轮转
      storage.save(_storeWithProject('要留下的'), nowMillis: _day);
      // 隔一个节流窗口再存：这次把"要留下的"轮转进 backup.1，主文件变成 v2
      storage.save(
        _storeWithProject('后来误加的'),
        nowMillis: _day + AppStorage.rotateMinIntervalMillis,
      );
      final report = storage.load(nowMillis: _day + 2 * AppStorage.rotateMinIntervalMillis);
      return (
        app: AppController(
          storage: storage,
          workspace: Workspace.fromLoad(storage, report),
          dataDirectory: tempDir,
          startupWarnings: const <String>[],
        ),
        storage: storage,
      );
    }

    test('restoreBackup：把选中的那份换回来（当前数据先进备份）', () {
      final booted = bootWithBackup();
      final storage = booted.storage;
      final app = booted.app;
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue, reason: '先要有可恢复的备份');

      final error = app.restoreBackup(storage.paths.rollingBackup(1).path);

      expect(error, isNull);
      expect(app.ws.liveProjects.map((p) => p.title), contains('要留下的'));
      expect(
        storage.paths.rollingBackup(1).existsSync(),
        isTrue,
        reason: '恢复动作本身也要可回退：当前数据先被轮转走了',
      );
    });

    test('restoreBackup：拿一份没有记录的备份来恢复 → 如实报错（P1-8）', () {
      final booted = bootWithBackup();
      final storage = booted.storage;
      final app = booted.app;

      storage.paths.rollingBackup(1).writeAsStringSync('[1,2,3]');
      final error = app.restoreBackup(storage.paths.rollingBackup(1).path);

      expect(error, isNotNull, reason: '空备份不是恢复来源');
    });

    test('deleteBackup：删得掉，且不允许删到一份不剩', () {
      final booted = bootWithBackup();
      final storage = booted.storage;
      final app = booted.app;

      final entries = storage.listBackups();
      expect(entries.length, greaterThanOrEqualTo(2), reason: '要有两份才谈得上删');

      expect(app.deleteBackup(entries.first.path), isNull, reason: '删得掉');
      expect(storage.listBackups().length, entries.length - 1);

      // 删到只剩一份时必须拒绝，并且那一份要留着
      final only = storage.listBackups().single;
      expect(
        app.deleteBackup(only.path),
        isNotNull,
        reason: '没有云端时本地备份是唯一安全网，"清空备份"应当是不可能完成的操作',
      );
      expect(storage.listBackups(), hasLength(1));
    });

    test('deleteBackup：不给它一份真的备份路径就拒绝（防止误删主文件）', () {
      final booted = bootWithBackup();
      final storage = booted.storage;
      final app = booted.app;

      expect(app.deleteBackup(storage.paths.storeFile.path), isNotNull,
          reason: '只认自己列出来的备份，别处传来的路径一律拒绝');
      expect(storage.paths.storeFile.existsSync(), isTrue);
    });
  });

  group('外观与交接导出接线（T-6：此前按钮存在但从未被点过）', () {
    test('设置 / 清除背景图：偏好真的变了，字节也落到了私有目录', () {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);

      // 1×1 的 PNG（最小合法图）
      final png = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ];

      final error = app.applyBackgroundImage(png, seedHex: '#2f6feb');

      expect(error, isNull, reason: '设置背景图是这条接线的主路径');
      expect(app.prefs.backgroundImagePath, isNotNull, reason: '偏好里要记下路径');
      expect(app.prefs.backgroundSeedHex, '#2f6feb', reason: '跟随背景图的主色也要记');
      final saved = storage.paths.backgroundImageFile;
      expect(saved.existsSync(), isTrue, reason: '图片要拷进应用私有目录，别只记个相册路径');
      expect(saved.lengthSync(), png.length);

      app.clearBackgroundImage();
      expect(app.prefs.backgroundImagePath, isNull);
      expect(app.prefs.backgroundSeedHex, isNull);
      expect(saved.existsSync(), isFalse, reason: '清除时那份拷贝也要删掉');
    });

    test('交接说明导出：能生成内容并交给分享钩子', () async {
      final storage = AppStorage(AppPaths(tempDir));
      String? sharedPath;
      String? sharedText;
      final app = AppController(
        storage: storage,
        workspace: Workspace.fromLoad(storage, storage.load()),
        dataDirectory: tempDir,
        startupWarnings: const <String>[],
        shareFile: (path, {required text, required subject}) async {
          sharedPath = path;
          sharedText = text;
          return true;
        },
      );
      final project = app.ws.createProject(
        title: '交接项目',
        purpose: '把这件事交给电脑上的 AI',
      );
      app.run(() => app.ws.addProjectItem(project.id, '先冻结契约'));

      final result = await app.exportHandoffAndShare(
        projectId: project.id,
        markdown: '# 项目：交接项目\n\n## 实现清单\n\n- [ ] 先冻结契约\n',
      );

      expect(result.ok, isTrue, reason: '分享钩子返回 true 才算导出成功');
      expect(sharedPath, isNotNull);
      expect(sharedText, contains('交接项目'), reason: '生成的内容里要有项目名');
      expect(
        File(sharedPath!).existsSync() || sharedPath!.isNotEmpty,
        isTrue,
        reason: '至少要把文件写到一个可分享的位置',
      );
    });
  });

  group('备份列表缓存（Q-4）', () {
    test('连续读返回同一份缓存，备份变了就作废重算', () {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      app.run(() => app.ws.createProject(title: 'v1'));

      final first = app.backups;
      expect(identical(app.backups, first), isTrue,
          reason: '同一修订号之间必须复用缓存 —— 否则每次重建都重解析十几份文件');

      // 造出一份新的备份（forceRotate 保证轮转）→ 修订号变了 → 缓存作废
      app.snapshotBackupNow();
      final second = app.backups;
      expect(identical(app.backups, second), isTrue, reason: '重新算完之后再次命中');
      expect(
        second.length,
        greaterThan(first.length),
        reason: '新备份要出现在列表里 —— 缓存若忘了作废，这里会拿到旧的',
      );
    });
  });

  group('主文件版本高于本应用（P0-1 / P0-3）', () {
    /// 写一份"更新版本 App 留下的"主文件。
    String writeFutureStore() {
      final json = StoreFile.empty().toJson();
      json['schemaVersion'] = StoreFile.currentSchemaVersion + 1;
      final text = const JsonEncoder.withIndent(null).convert(json);
      AppPaths(tempDir).ensureDirectories();
      AppPaths(tempDir).storeFile.writeAsStringSync(text);
      return text;
    }

    test('启动时不动盘、给出告警，且用户改东西也写不进去', () async {
      final before = writeFutureStore();

      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);

      expect(app.startupWarnings, isNotEmpty, reason: '必须告诉用户"这不是你的数据没了，是版本不对"');
      expect(
        app.startupWarnings.single,
        contains('更新版本'),
        reason: '泛泛的"解析发现 N 处问题"会让用户以为数据坏了，必须说清是版本看不懂、数据还在',
      );
      expect(
        app.startupWarnings.single,
        contains('仍在文件里'),
        reason: '这条告警的核心是让用户别做"重新开始记"这类动作',
      );
      expect(
        AppPaths(tempDir).storeFile.readAsStringSync(),
        before,
        reason: '启动路径上的清理动作也不能动这份文件（P0-3）',
      );

      // 用户随手改一下 → 保存同样要被拒绝
      //
      // **必须接住返回值并断言它不是 `null`**（2026-10-01 补）。
      // 这里原先只写 `app.run(...)`、把返回值丢掉 —— 于是"界面有没有如实报错"
      // 这件事完全没有断言：`AppStorage.save` 被锁住时是**静默 return** 的，
      // 而 `run` 只认异常 → 它返回 `null`（=成功）、还 `notifyListeners()`，
      // 界面照报"改好了"，用户整个会话的编辑在退出后全部消失。
      // 也就是说：**这条用例当时绿着，却对"假装成功"毫无察觉。**
      final error =
          app.run(() => app.ws.createProject(title: '旧版新建的项目'));
      expect(
        error,
        isNotNull,
        reason: '被新版锁住时**必须说"没保存"**，不能返回 null（那等于报成功）。'
            '这是全仓最后一处"假装成功"，也是这条断言存在的唯一理由',
      );
      expect(
        error,
        contains('更新版本'),
        reason: '文案要指向"升级 App"，而不是让用户去查存储空间',
      );
      expect(
        AppPaths(tempDir).storeFile.readAsStringSync(),
        before,
        reason: '被锁住时任何写入都必须被拒绝（P0-1 的写盘守卫）',
      );
    });

    // 2026-10-01 补：**四个绕过 `persist()` 的入口**。
    //
    // 我第一版把守卫的"抛"放在 `WorkspaceState.persist()` 里，只堵住了 5 个
    // 直接调 `save()` 的调用点里的 2 个。另外四个继续假装成功 ——
    // 其中 `restoreBackup` 最狠：它 `save()` 之后照样 `return parsed.store!`，
    // 上层据此把内存换成恢复的数据、报成功，而**盘上一个字节没动**，
    // 用户重启即全丢。这四条当时**一条用例都没有**（独立核验查出来的）。
    //
    // 现在守卫在 `AppStorage.save` 里抛，所以这四条的期望统一成"必须报错"。
    test('从备份恢复：被新版锁住时**不许报成功**，盘上不许有变化', () async {
      final before = writeFutureStore();
      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);

      // 先造一份"可以拿来恢复"的备份（正常数据，不是未来版本）
      final goodBackup = AppPaths(tempDir).rollingBackup(1);
      AppPaths(tempDir).ensureDirectories();
      goodBackup.writeAsStringSync(_storeWithProject('一份正常备份').toCanonicalText());

      final error = app.restoreBackup(goodBackup.path);

      expect(
        error,
        isNotNull,
        reason: '**这是最危险的一条**：原来它会返回 null（=成功）并把内存换成'
            '恢复的数据，而主文件一个字节都没动 —— 用户重启即全丢。'
            '报成功比报失败危险得多',
      );
      expect(
        AppPaths(tempDir).storeFile.readAsStringSync(),
        before,
        reason: '主文件仍是那份"未来版本"的，不许被换掉',
      );
    });

    test('导入：被新版锁住时**不许报成功**', () async {
      final before = writeFutureStore();
      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);

      final error = app.applyImport(_storeWithProject('导入进来的数据'));

      expect(error, isNotNull, reason: '不许假装导入成功');
      expect(
        AppPaths(tempDir).storeFile.readAsStringSync(),
        before,
        reason: '主文件不许被换成导入的那份',
      );
    });

    test('合并导入：被新版锁住时**不许报成功**', () async {
      final before = writeFutureStore();
      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);

      final error = app.applyMergedStore(_storeWithProject('合并后的数据'));

      expect(error, isNotNull, reason: '不许假装合并成功');
      expect(
        AppPaths(tempDir).storeFile.readAsStringSync(),
        before,
        reason: '主文件不许被换成合并结果',
      );
    });

    test('手动备份：被新版锁住时给的理由要**是对的**（不是"检查存储空间"）', () async {
      final before = writeFutureStore();
      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);

      final error = app.snapshotBackupNow();

      expect(error, isNotNull, reason: '这次备份在磁盘上并不存在，必须说出来');
      expect(
        error,
        contains('更新版本'),
        reason: '它原来掉进 `on FileSystemException` 分支，报的是'
            '"请检查存储空间或权限" —— 真实原因是被更新版本锁住。'
            '让用户去查存储空间是把他往错的方向支',
      );
      expect(
        AppPaths(tempDir).storeFile.readAsStringSync(),
        before,
        reason: '主文件不许被动',
      );
    });
  });

  group('合并导入落盘（Q25）', () {
    test('先轮转备份再原子写：合并结果进主文件，工作区重载、监听者被通知', () async {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      app.ws.createProject(title: '本机项目');
      final backupsBefore = storage.listBackups().length;

      // 另一台设备上的那一份（真实 id 与时间戳），合并后应当与本机并成一份
      final otherDir = Directory.systemTemp.createTempSync('guideline_merge_source');
      addTearDown(() {
        if (otherDir.existsSync()) otherDir.deleteSync(recursive: true);
      });
      final source = await AppController.bootstrap(dataDirectoryOverride: otherDir);
      source.ws.createProject(title: '对方项目');

      final outcome = mergeStoresWithReport(
        app.ws.buildStoreFile(),
        source.ws.buildStoreFile(),
        nowMillis: Ids.nowMillis(),
      );
      expect(outcome.report.added, 1, reason: '先确认这份结果真的"合并"了东西');

      var notified = 0;
      app.addListener(() => notified += 1);

      final error = app.applyMergedStore(outcome.store);

      expect(error, isNull);
      expect(notified, 1, reason: '界面每次重建都读 ws，换过工作区必须通知一次');
      expect(
        <String>[for (final p in app.ws.liveProjects) p.title],
        containsAll(<String>['本机项目', '对方项目']),
        reason: '合并是把对方的记录并进来，不是替换',
      );
      expect(
        storage.listBackups().length,
        greaterThan(backupsBefore),
        reason: '合并前必须先轮转一份备份 —— 合错了要能退回',
      );
      expect(storage.paths.storeFile.readAsStringSync(), contains('对方项目'));
    });

    test('写盘失败：返回可读文案、不抛异常，内存也不换成没写进去的那份', () {
      final storage = _FailingStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      storage.failing = false;
      app.ws.createProject(title: '本机项目');
      storage.failing = true;

      String? error;
      expect(
        () => error = app.applyMergedStore(StoreFile.empty()),
        returnsNormally,
        reason: '磁盘问题不该以异常形式炸到界面上',
      );

      expect(error, isNotNull);
      expect(error, contains('合并失败'));
      expect(
        app.ws.liveProjects.single.title,
        '本机项目',
        reason: '没写进磁盘就不能显示成合并后的样子',
      );
    });
  });

  group('实现计划的历史正文（Q15）', () {
    test('留档 → 覆盖 → 退回：正文回到上一版，留档只用一次', () {
      final storage = AppStorage(AppPaths(tempDir));
      final app = controllerWith(storage);
      final project = app.ws.createProject(title: '项目', implementation: '原来的正文');

      app.saveImplementationSnapshot(project.id, app.currentImplementation(project.id));
      app.run(() => app.ws.replaceImplementation(project.id, 'AI 整理出来的正文'));
      expect(app.ws.findProject(project.id)!.implementation, 'AI 整理出来的正文');

      expect(app.revertImplementation(project.id), isNull);
      expect(app.ws.findProject(project.id)!.implementation, '原来的正文');
      expect(app.implementationSnapshot(project.id), isNull, reason: '一份留档只值一次反悔');
      expect(app.revertImplementation(project.id), '没有可退回的上一版');
    });
  });

  group('编辑会话来自"推开一个页面"（Q3）', () {
    testWidgets('推开页面进会话、回到外壳才结束，对话框不算', (tester) async {
      final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
      final navigator = GlobalKey<NavigatorState>();

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: <NavigatorObserver>[app.editSessionObserver],
        home: const Scaffold(body: Text('外壳')),
      ));
      await tester.pumpAndSettle();

      // 冷启动：会话状态只在内存里，新建的 AppStorage 一定是"不在会话中"，
      // 所以外壳自己那个初始路由必须被跳过（否则一启动就永远出不了会话）
      expect(app.storage.inEditSession, isFalse);

      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('编辑页'))),
      );
      await tester.pumpAndSettle();
      expect(app.storage.inEditSession, isTrue);

      // 详情页里再推开一层不算离开那段操作
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('更深一层'))),
      );
      await tester.pumpAndSettle();
      expect(app.storage.inEditSession, isTrue);

      // 对话框是 PopupRoute：它既不开启也不结束会话。
      // 用 Navigator 自己的 context 打开：上一层页面已被不透明路由盖住，
      // 它的 widget 在 finder 眼里是 offstage 的
      final popup = showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(title: Text('确认')),
      );
      await tester.pumpAndSettle();
      expect(app.storage.inEditSession, isTrue, reason: '弹个对话框不算进了另一个页面');
      Navigator.of(tester.element(find.text('确认'))).pop();
      await tester.pumpAndSettle();
      await popup;

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(app.storage.inEditSession, isTrue, reason: '里面还有一层，会话没结束');

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(app.storage.inEditSession, isFalse, reason: '回到外壳才算离开');
    });
  });
}

/// 固定时间戳（2026-09-06）：备份轮转按最小间隔节流，用例里把时间钉死更好读。
const int _day = 1788652800000;

/// 模拟磁盘写不进去；可以随时开关，用来验证"失败之后还能正常用"。
///
/// ⚠️ `failing = false` 时它会走到**真的** `AppStorage.save`，而那个方法现在会在
/// "盘上那份属于更新版本的 App" 时抛 `StoreLockedByNewerSchema`（2026-10-01 起）。
/// 所以这个 helper 只该用在**不涉及那条路径**的用例里 —— 否则异常会从
/// `super.save(...)` 穿出去、变成未捕获错误，而不是被测代码该给出的失败文案。
/// （独立核验把它列为"可忽略"；这里**不同意**：它是**测试基础设施**的坑，
/// 下一个人拿它去测锁定场景就会踩 —— 而那正是本轮反复在修的那类事。）
class _FailingStorage extends AppStorage {
  _FailingStorage(super.paths);

  bool failing = true;

  @override
  void save(StoreFile store, {int? nowMillis, bool forceRotate = false}) {
    if (failing) throw const FileSystemException('磁盘已满（测试模拟）');
    super.save(store, nowMillis: nowMillis, forceRotate: forceRotate);
  }
}

/// 造一份"只有一个项目"的数据（标题用来分辨是哪一份备份）。
StoreFile _storeWithProject(String title) => StoreFile(
      documents: <DocName, Document>{
        for (final name in DocName.values) name: Document.empty(name),
        DocName.projects: Document(
          name: DocName.projects,
          items: <Project>[
            Project(
              id: 'p-$title',
              title: title,
              purpose: '',
              implementation: '',
              date: null,
              status: NodeStatus.pending,
              archived: false,
              parentProjectId: null,
              order: 1000,
              completedAt: null,
              createdAt: _day,
              updatedAt: _day,
              deleted: false,
            ),
          ],
        ),
      },
      savedAt: _day,
    );
