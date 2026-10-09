import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/features/workspace.dart';

/// **任务待办清单**那一块的测试（《数据契约》§3.4.2）。
///
/// 这一块最要紧的三条边界，就是这份文件要守住的东西：
///   1. **只动宿主任务** —— 勾一条待办不会改任务状态、不会碰子任务；
///   2. **不参与判定** —— 待办全勾完**不会**把任务变成已完成，
///      待办没勾完也**不阻塞**任务完成；父任务那把锁仍旧只算子任务；
///   3. **坏数据只丢它自己** —— 解析口径与项目清单**同一套**（共用 `ProjectItem`，
///      那条由 `task_checklist_model_test` 守）。
///
/// 夹具走 `AppController.bootstrap`（临时目录）：`Workspace` 与它内部那份
/// `WorkspaceState` 因此是**同一份文档**，读判定（`isTaskBlocked`）与写待办
/// 不会各看各的 —— 早先手搭两份文档时，子任务建在 A 份、判定读的是 B 份，
/// 用例会莫名其妙地红。
void main() {
  late Directory tempDir;
  late Workspace ws;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('guideline_task_checklist_');
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    ws = app.ws;
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 造一条主线任务（挂在一条事件下）。
  Task seedTask(String title) {
    final event = ws.createEvent(name: '演示事件');
    return ws.createTask(eventId: event.id, title: title);
  }

  group('增删改查', () {
    test('加一条：追加在末尾、默认没勾、真的落盘', () {
      final task = seedTask('写解析层');
      final first = ws.addTaskChecklistItem(task.id, '先写契约');
      final second = ws.addTaskChecklistItem(task.id, '  再写实现  ');

      expect(
        ws.taskChecklistOf(task.id).map((i) => i.text),
        <String>['先写契约', '再写实现'],
        reason: '两端空白要 trim 掉；顺序就是数组顺序',
      );
      expect(first.done, isFalse);
      expect(second.done, isFalse);
    });

    test('空文本拒绝；任务不存在拒绝', () {
      final task = seedTask('写解析层');
      expect(
        () => ws.addTaskChecklistItem(task.id, '   '),
        throwsA(isA<RuleViolation>()),
      );
      expect(
        () => ws.addTaskChecklistItem('not-a-task', '随便'),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('改文字：真改了才落盘，空文本拒绝', () {
      final task = seedTask('写解析层');
      final item = ws.addTaskChecklistItem(task.id, '原文');
      final before = ws.findTask(task.id)!.updatedAt;

      // 一模一样（只差两端空白）→ 不写盘
      ws.updateTaskChecklistItemText(task.id, item.id, '  原文  ');
      expect(ws.findTask(task.id)!.updatedAt, before, reason: '没变就不该写盘');

      ws.updateTaskChecklistItemText(task.id, item.id, '改过的');
      expect(ws.taskChecklistOf(task.id).single.text, '改过的');
      expect(
        () => ws.updateTaskChecklistItemText(task.id, item.id, ' '),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('勾选：来回切换都认，重复设置同一个值是空操作', () {
      final task = seedTask('写解析层');
      final item = ws.addTaskChecklistItem(task.id, '一条');

      ws.setTaskChecklistItemDone(task.id, item.id, true);
      expect(ws.taskChecklistSummary(task.id), (done: 1, total: 1));

      final after = ws.findTask(task.id)!.updatedAt;
      ws.setTaskChecklistItemDone(task.id, item.id, true);
      expect(ws.findTask(task.id)!.updatedAt, after);

      ws.setTaskChecklistItemDone(task.id, item.id, false);
      expect(ws.taskChecklistSummary(task.id), (done: 0, total: 1));
    });

    test('删一条：找不到的条目要抛，不能静默什么都不发生', () {
      final task = seedTask('写解析层');
      final a = ws.addTaskChecklistItem(task.id, 'A');
      ws.addTaskChecklistItem(task.id, 'B');

      ws.removeTaskChecklistItem(task.id, a.id);
      expect(ws.taskChecklistOf(task.id).map((i) => i.text), <String>['B']);
      expect(
        () => ws.removeTaskChecklistItem(task.id, a.id),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('清空：本来就空时不落盘（白轮转一次备份没有意义）', () {
      final task = seedTask('写解析层');
      final before = ws.findTask(task.id)!.updatedAt;
      ws.clearTaskChecklist(task.id);
      expect(ws.findTask(task.id)!.updatedAt, before);

      ws.addTaskChecklistItem(task.id, '一条');
      ws.clearTaskChecklist(task.id);
      expect(ws.taskChecklistOf(task.id), isEmpty);
    });

    test('读：任务不存在时给空表，不抛（列表页每帧都会问一次）', () {
      expect(ws.taskChecklistOf('not-a-task'), isEmpty);
      expect(ws.taskChecklistSummary('not-a-task'), (done: 0, total: 0));
    });
  });

  group('边界：不参与任何判定', () {
    test('勾完所有待办**不会**把任务变成已完成', () {
      final task = seedTask('写解析层');
      final a = ws.addTaskChecklistItem(task.id, 'A');
      final b = ws.addTaskChecklistItem(task.id, 'B');
      ws.setTaskChecklistItemDone(task.id, a.id, true);
      ws.setTaskChecklistItemDone(task.id, b.id, true);

      final after = ws.findTask(task.id)!;
      expect(after.status, NodeStatus.pending,
          reason: '待办只是细则：全勾完也不许自动完成任务（自动"完成"是禁止的）');
      expect(after.completedAt, isNull);
    });

    test('待办没勾完**不阻塞**父任务完成（锁只算子任务）', () {
      final event = ws.createEvent(name: '演示事件');
      final parent = ws.createTask(eventId: event.id, title: '写解析层');
      final child = ws.createTask(
        eventId: event.id,
        title: '子任务甲',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );
      ws.addTaskChecklistItem(parent.id, '还没勾的细则');

      // 子任务做完 ⇒ 父任务可以完成（待办没勾完也不影响）
      ws.setTaskStatus(child.id, NodeStatus.done);
      expect(ws.isTaskBlocked(parent.id), isFalse, reason: '父任务的锁只看子任务，不看待办');

      ws.setTaskStatus(parent.id, NodeStatus.done);
      expect(ws.findTask(parent.id)!.status, NodeStatus.done);
    });

    test('勾待办不动任务状态、不动子任务', () {
      final event = ws.createEvent(name: '演示事件');
      final parent = ws.createTask(eventId: event.id, title: '写解析层');
      final child = ws.createTask(
        eventId: event.id,
        title: '子任务甲',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );
      final item = ws.addTaskChecklistItem(parent.id, '一条');
      final childBefore = ws.findTask(child.id)!;

      ws.setTaskChecklistItemDone(parent.id, item.id, true);

      expect(ws.findTask(parent.id)!.status, NodeStatus.pending);
      expect(ws.findTask(child.id)!.status, childBefore.status);
      expect(ws.findTask(child.id)!.updatedAt, childBefore.updatedAt);
    });

    test('任务被完成后待办照旧能改（没有"已完成任务不许动待办"这条规矩）', () {
      final task = seedTask('写解析层');
      final item = ws.addTaskChecklistItem(task.id, '一条');
      ws.setTaskStatus(task.id, NodeStatus.done);

      ws.setTaskChecklistItemDone(task.id, item.id, true);
      expect(ws.taskChecklistSummary(task.id), (done: 1, total: 1));
      expect(ws.findTask(task.id)!.status, NodeStatus.done);
    });
  });
}
