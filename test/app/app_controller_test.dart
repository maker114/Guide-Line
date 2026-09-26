import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/ids.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/core/store/ui_prefs.dart';
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
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
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

/// 固定时间戳：备份轮转按最小间隔节流，用例里把时间钉死更好读。
const int _day = 1788652800000; // 2026-09-06

/// 模拟磁盘写不进去；可以随时开关，用来验证"失败之后还能正常用"。
class _FailingStorage extends AppStorage {
  _FailingStorage(super.paths);

  bool failing = true;

  @override
  void save(StoreFile store, {int? nowMillis, bool forceRotate = false}) {
    if (failing) throw const FileSystemException('磁盘已满（测试模拟）');
    super.save(store, nowMillis: nowMillis, forceRotate: forceRotate);
  }
}
