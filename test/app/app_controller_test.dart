import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/features/workspace.dart';

/// 写盘失败时的行为（磁盘满 / 权限被拒）。
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

  AppController controllerWith(AppStorage storage) {
    final report = storage.load();
    return AppController(
      storage: storage,
      workspace: Workspace.fromLoad(storage, report),
      dataDirectory: tempDir,
      startupWarnings: const <String>[],
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
}

/// 模拟磁盘写不进去；可以随时开关，用来验证"失败之后还能正常用"。
class _FailingStorage extends AppStorage {
  _FailingStorage(super.paths);

  bool failing = true;

  @override
  void save(StoreFile store, {int? nowMillis}) {
    if (failing) throw const FileSystemException('磁盘已满（测试模拟）');
    super.save(store, nowMillis: nowMillis);
  }
}
