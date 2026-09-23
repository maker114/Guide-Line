import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/core/tree/task_flow.dart';
import 'package:guideline/features/workspace.dart';

/// 任务走向的**写入规则**（分叉 / 合流）。
///
/// 最要紧的一条是 `materializeTaskChain`：`TaskFlow` 的规则是
/// "整条线只要有一个显式边，就全部按显式边解释"，所以用户第一次加边时
/// 必须先把原有隐式链整段固化下来 —— 否则其余节点会瞬间失去顺序、
/// 散成一堆孤立入口。下面第一条用例就是守这个坑。
void main() {
  late Directory dir;
  late AppStorage storage;
  late Workspace ws;
  late String eventId;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_flow_rules_');
    storage = AppStorage(AppPaths(dir));
    ws = Workspace.fromLoad(storage, storage.load());
    eventId = ws.createEvent(name: '分叉演示').id;
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  List<Task> mainLine() => ws.mainLineOf(eventId);

  TaskFlow flow() => TaskFlow.of(ws.allTasks, eventId: eventId);

  group('固化隐式链', () {
    test('把按 order 的链写成显式边，而且顺序不变', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');
      final c = ws.createTask(eventId: eventId, title: 'C');
      expect(flow().usesExplicitEdges, isFalse, reason: '一开始是隐式链');

      ws.materializeTaskChain(eventId);

      final after = flow();
      expect(after.usesExplicitEdges, isTrue);
      expect(ws.findTask(a.id)!.nextIds, <String>[b.id]);
      expect(ws.findTask(b.id)!.nextIds, <String>[c.id]);
      expect(ws.findTask(c.id)!.nextIds, isEmpty);
      expect(after.roots.map((t) => t.id), <String>[a.id], reason: '入口还是 A');
      expect(after.sinks.map((t) => t.id), <String>[c.id], reason: '出口还是 C');
    });

    test('已经是显式边时不动它', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');
      ws.addTaskNext(a.id, b.id);
      final before = ws.findTask(a.id)!.nextIds;

      ws.materializeTaskChain(eventId);

      expect(ws.findTask(a.id)!.nextIds, before);
    });

    test('空事件与单节点事件都不会出问题', () {
      expect(() => ws.materializeTaskChain(eventId), returnsNormally);
      final only = ws.createTask(eventId: eventId, title: '只有一个');
      ws.materializeTaskChain(eventId);
      expect(ws.findTask(only.id)!.nextIds, isEmpty);
    });
  });

  group('分叉 / 合流', () {
    test('加第二条后续边就成了分叉', () {
      final a = ws.createTask(eventId: eventId, title: '起点');
      final b = ws.createTask(eventId: eventId, title: '支路甲');
      final c = ws.createTask(eventId: eventId, title: '支路乙');

      ws.setTaskNext(a.id, <String>[b.id]);
      expect(flow().isFork(a.id), isFalse);

      ws.addTaskNext(a.id, c.id);
      expect(flow().isFork(a.id), isTrue);
      expect(flow().hasFork, isTrue);
    });

    test('两条支路接回同一个任务就成了合流', () {
      final a = ws.createTask(eventId: eventId, title: '起点');
      final b = ws.createTask(eventId: eventId, title: '支路甲');
      final c = ws.createTask(eventId: eventId, title: '支路乙');
      final d = ws.createTask(eventId: eventId, title: '汇合');

      ws.setTaskNext(a.id, <String>[b.id, c.id]);
      ws.setTaskNext(b.id, <String>[d.id]);
      ws.setTaskNext(c.id, <String>[d.id]);

      final graph = flow();
      expect(graph.isFork(a.id), isTrue);
      expect(graph.isJoin(d.id), isTrue);
      expect(graph.hasJoin, isTrue);
    });

    test('断开一条后续边就退回单线', () {
      final a = ws.createTask(eventId: eventId, title: '起点');
      final b = ws.createTask(eventId: eventId, title: '支路甲');
      final c = ws.createTask(eventId: eventId, title: '支路乙');
      ws.setTaskNext(a.id, <String>[b.id, c.id]);

      ws.removeTaskNext(a.id, c.id);

      expect(ws.findTask(a.id)!.nextIds, <String>[b.id]);
      expect(flow().isFork(a.id), isFalse);
    });
  });

  group('写入校验', () {
    test('不能接到自己后面', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      expect(
        () => ws.addTaskNext(a.id, a.id),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('不能接到自己后面（绕回来也不行）', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');
      final c = ws.createTask(eventId: eventId, title: 'C');
      ws.setTaskNext(a.id, <String>[b.id]);
      ws.setTaskNext(b.id, <String>[c.id]);

      // C → A 会成环
      expect(() => ws.setTaskNext(c.id, <String>[a.id]), throwsA(isA<RuleViolation>()));
      // C → B 也会
      expect(() => ws.setTaskNext(c.id, <String>[b.id]), throwsA(isA<RuleViolation>()));
      // 但 C 之后接一个"没人指向"的 A' 是允许的（接到 A 前面则不行）——这里直接接 D
      final d = ws.createTask(eventId: eventId, title: 'D');
      expect(() => ws.setTaskNext(c.id, <String>[d.id]), returnsNormally);
    });

    test('不能接到其它事件的任务后面', () {
      final mine = ws.createTask(eventId: eventId, title: '本事件的');
      final otherEvent = ws.createEvent(name: '别的事件');
      final theirs = ws.createTask(eventId: otherEvent.id, title: '别的事件的');

      expect(
        () => ws.addTaskNext(mine.id, theirs.id),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('不能接到子任务后面（子任务不在走向上）', () {
      final main = ws.createTask(eventId: eventId, title: '主线');
      final sub = ws.createTask(
        eventId: eventId,
        title: '子任务',
        parentTaskId: main.id,
        type: TaskType.subtask,
      );

      expect(() => ws.addTaskNext(main.id, sub.id), throwsA(isA<RuleViolation>()));
      expect(() => ws.setTaskNext(sub.id, <String>[main.id]), throwsA(isA<RuleViolation>()));
    });

    test('重复的后续边会被去掉', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');
      ws.setTaskNext(a.id, <String>[b.id, b.id]);
      expect(ws.findTask(a.id)!.nextIds, <String>[b.id]);
    });
  });

  group('新建任务如何接进走向', () {
    test('显式模式下新建主线任务会接在当前所有出口之后', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');
      ws.setTaskNext(a.id, <String>[b.id]);

      final c = ws.createTask(eventId: eventId, title: 'C');

      expect(ws.findTask(b.id)!.nextIds, <String>[c.id]);
      expect(flow().sinks.map((t) => t.id), <String>[c.id]);
    });

    test('两条支路都开着时，新任务会接到两条之后（形成合流）', () {
      final a = ws.createTask(eventId: eventId, title: '起点');
      final b = ws.createTask(eventId: eventId, title: '支路甲');
      // 在起点后面再开一条支路：先固化 a→b，再把新支路也接到 a
      final c = ws.createTask(eventId: eventId, title: '支路乙', linkAfterTaskId: a.id);
      expect(flow().isFork(a.id), isTrue);

      // 两条支路都开着，这时新建的任务会接在两条之后 —— 也就是一个合流点
      final d = ws.createTask(eventId: eventId, title: '收口');

      expect(flow().isJoin(d.id), isTrue);
      expect(ws.findTask(b.id)!.nextIds, <String>[d.id]);
      expect(ws.findTask(c.id)!.nextIds, <String>[d.id]);
      expect(flow().roots.map((t) => t.id), <String>[a.id]);
    });

    test('在这里分叉时不会把原有顺序弄丢（先固化再加边）', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');

      // 关键：加边的同时，原本按 order 的 a→b 必须还在
      final branch = ws.createTask(eventId: eventId, title: '新支路', linkAfterTaskId: a.id);

      expect(ws.findTask(a.id)!.nextIds, <String>[b.id, branch.id]);
      expect(flow().roots.map((t) => t.id), <String>[a.id], reason: 'B 不能变成孤立入口');
      expect(flow().successorsOf(a.id).map((t) => t.id), <String>[b.id, branch.id]);
    });

    test('可以指定接在某个任务之后（"在这里分叉"）', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');
      ws.setTaskNext(a.id, <String>[b.id]);

      final branch = ws.createTask(eventId: eventId, title: '新支路', linkAfterTaskId: a.id);

      expect(ws.findTask(a.id)!.nextIds, <String>[b.id, branch.id]);
      expect(flow().isFork(a.id), isTrue);
    });

    test('链式模式下新建任务不产生显式边（顺序仍由 order 决定）', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');

      expect(ws.findTask(a.id)!.nextIds, isEmpty);
      expect(ws.findTask(b.id)!.nextIds, isEmpty);
      expect(flow().usesExplicitEdges, isFalse);
      expect(mainLine().map((t) => t.id), <String>[a.id, b.id]);
    });
  });

  group('落盘与重载', () {
    test('后续边会写进数据文件，重载后仍在', () {
      final a = ws.createTask(eventId: eventId, title: 'A');
      final b = ws.createTask(eventId: eventId, title: 'B');
      ws.setTaskNext(a.id, <String>[b.id]);

      final reloaded = Workspace.fromLoad(storage, storage.load());

      expect(reloaded.findTask(a.id)!.nextIds, <String>[b.id]);
      expect(TaskFlow.of(reloaded.allTasks, eventId: eventId).usesExplicitEdges, isTrue);
    });
  });
}
