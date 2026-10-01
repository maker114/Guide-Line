import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/ids.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/event.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/project_item.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/core/store/app_paths.dart';
// `workspace.dart` 把 `AppStorage` / `UiPrefs` / `RuleViolation` /
// `WorkspaceState` / `WorkspaceChecklist` 都再导出着，所以这一条就够了 ——
// 另外三条 import 会被 `unnecessary_import` 挡下（试过）。
import 'package:guideline/features/workspace.dart';

/// **`WorkspaceChecklist` 自己的测试** —— 不经过 `Workspace` 门面调那几个方法。
///
/// ## 这份文件为什么存在
///
/// 「实现清单」那一块从 `workspace.dart` 搬出来时，定的验收标准是
/// **"搬完能被独立测试"**，不只是"文件变小了"。搬迁当时它**没有**自己的测试：
/// 逻辑仍然只被 `workspace_test.dart`（2144 行）与 `project_checklist_test.dart`
/// 通过**门面**覆盖 —— 而门面转发一旦写错（漏一个 `persist()`、转错参数），
/// 那些用例照样可能全绿。
///
/// 本文件的定位与 `test/core/` 下那 20 个直测纯函数/无状态类的文件一致：
/// **对着被搬出来的那个类写，不经过门面**。
void main() {
  late _Harness h;

  setUp(() {
    h = _Harness();
  });

  tearDown(() {
    h.dispose();
  });

  group('增删改：条目本身与落盘', () {
    test('加一条：trim 后写入、done 为 false、磁盘上立刻能看到', () {
      final project = h.seedProject();

      final item = h.checklist.addProjectItem(project.id, '  写一段说明  ');

      expect(item.text, '写一段说明', reason: '前后空白要去掉');
      expect(item.done, isFalse);
      expect(h.itemsInMemory(project.id).length, 1);
      expect(h.itemTextsOnDisk(project.id), <String>['写一段说明'],
          reason: '这一块必须立刻落盘（改一下存一下）');
    });

    test('空内容被拒绝，且不留下半条记录', () {
      final project = h.seedProject();

      expect(
        () => h.checklist.addProjectItem(project.id, '   '),
        throwsA(isA<RuleViolation>()),
      );
      expect(h.itemsInMemory(project.id), isEmpty);
      expect(h.itemTextsOnDisk(project.id), isEmpty);
    });

    test('改文字：trim、空值被拒、内容没变时不写盘', () {
      final project = h.seedProject();
      final item = h.checklist.addProjectItem(project.id, '原文');

      h.checklist.updateProjectItemText(project.id, item.id, '  改过的  ');
      expect(h.itemsInMemory(project.id).single.text, '改过的');
      expect(h.itemTextsOnDisk(project.id), <String>['改过的']);

      expect(
        () => h.checklist.updateProjectItemText(project.id, item.id, '   '),
        throwsA(isA<RuleViolation>()),
      );
      expect(h.itemsInMemory(project.id).single.text, '改过的', reason: '拒绝之后保持原值');

      // 内容没变：不该产生写盘。用 mtime 判"有没有写过" ——
      // 只断言内容不变是证明不了这件事的（内容本来就没变）。
      final before = h.storeMtime();
      h.sleepPastFilesystemTimestamp();
      h.checklist.updateProjectItemText(project.id, item.id, '改过的');
      expect(
        h.storeMtime(),
        before,
        reason: '文字与原值相同，这一笔不该落盘',
      );
    });

    test('打勾 / 取消打勾：只动 done，不动文字与顺序', () {
      final project = h.seedProject();
      final a = h.checklist.addProjectItem(project.id, '第一条');
      h.checklist.addProjectItem(project.id, '第二条');

      h.checklist.setProjectItemDone(project.id, a.id, true);
      expect(h.itemsInMemory(project.id).first.done, isTrue);
      expect(h.itemTextsOnDisk(project.id), <String>['第一条', '第二条'],
          reason: '打勾不该改文字或顺序');

      h.checklist.setProjectItemDone(project.id, a.id, false);
      expect(h.itemsInMemory(project.id).first.done, isFalse);
    });

    test('删一条：只删它自己；删不存在的条目会抛，不静默', () {
      final project = h.seedProject();
      final a = h.checklist.addProjectItem(project.id, '留下的');
      final b = h.checklist.addProjectItem(project.id, '删掉的');

      h.checklist.removeProjectItem(project.id, b.id);
      expect(h.itemTextsOnDisk(project.id), <String>['留下的']);

      expect(
        () => h.checklist.removeProjectItem(project.id, 'not-an-id'),
        throwsA(isA<RuleViolation>()),
        reason: '不存在时抛错，而不是"什么都没发生"',
      );
      expect(h.itemTextsOnDisk(project.id), <String>['留下的']);
      expect(h.itemsInMemory(project.id).single.id, a.id);
    });
  });

  group('顺序：就是数组下标', () {
    test('上移 / 下移交换相邻两条，磁盘上的顺序跟着变', () {
      final project = h.seedProject();
      final a = h.checklist.addProjectItem(project.id, 'A');
      h.checklist.addProjectItem(project.id, 'B');
      h.checklist.addProjectItem(project.id, 'C');

      h.checklist.moveProjectItem(project.id, a.id, 1);
      expect(h.itemTextsOnDisk(project.id), <String>['B', 'A', 'C']);

      h.checklist.moveProjectItem(project.id, a.id, -1);
      expect(h.itemTextsOnDisk(project.id), <String>['A', 'B', 'C']);
    });

    test('已经在两端时是空操作，不抛错', () {
      final project = h.seedProject();
      final a = h.checklist.addProjectItem(project.id, 'A');
      final b = h.checklist.addProjectItem(project.id, 'B');

      h.checklist.moveProjectItem(project.id, a.id, -1); // 顶到了头
      expect(h.itemTextsOnDisk(project.id), <String>['A', 'B']);

      h.checklist.moveProjectItem(project.id, b.id, 1); // 到底了
      expect(h.itemTextsOnDisk(project.id), <String>['A', 'B']);
    });

    test('一次只能挪一位：delta 不是 ±1 一律拒绝', () {
      final project = h.seedProject();
      final a = h.checklist.addProjectItem(project.id, 'A');
      h.checklist.addProjectItem(project.id, 'B');
      h.checklist.addProjectItem(project.id, 'C');

      for (final delta in <int>[0, 2, -2, 10]) {
        expect(
          () => h.checklist.moveProjectItem(project.id, a.id, delta),
          throwsA(isA<RuleViolation>()),
          reason: 'delta=$delta 应当被拒绝',
        );
      }
      expect(h.itemTextsOnDisk(project.id), <String>['A', 'B', 'C'],
          reason: '拒绝之后原样不动');
    });
  });

  group('正文 → 清单', () {
    test('按行拆：去掉 - / * / 1. 记号，丢空行', () {
      final lines = WorkspaceChecklist.splitImplementationLines(
        '- 第一条\n\n* 第二条\n1. 第三条\n2) 第四条\n   \n',
      );
      expect(lines, <String>['第一条', '第二条', '第三条', '第四条']);
    });

    test('拆条目：清单为空时允许，返回条数，全部 done=false', () {
      final project = h.seedProject();
      h.seedImplementation(project.id, '- 甲\n- 乙\n- 丙');

      final count = h.checklist.splitImplementationIntoItems(project.id);

      expect(count, 3);
      expect(h.itemTextsOnDisk(project.id), <String>['甲', '乙', '丙']);
      expect(
        h.itemsInMemory(project.id).every((i) => !i.done),
        isTrue,
        reason: '拆出来的是"打算怎么做"，不是"已经做完"',
      );
    });

    test('清单非空时拒绝拆 —— 不许把已有条目顶掉', () {
      final project = h.seedProject();
      h.seedImplementation(project.id, '- 甲\n- 乙');
      h.checklist.addProjectItem(project.id, '已有的一条');

      expect(
        () => h.checklist.splitImplementationIntoItems(project.id),
        throwsA(isA<RuleViolation>()),
      );
      expect(h.itemTextsOnDisk(project.id), <String>['已有的一条']);
    });

    test('正文里没有可拆的内容时拒绝', () {
      final project = h.seedProject();
      expect(
        () => h.checklist.splitImplementationIntoItems(project.id),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('整体替换：空文本项丢掉、重复的保留、返回实际写入条数', () {
      final project = h.seedProject();
      h.checklist.addProjectItem(project.id, '要被顶掉的旧条目');

      final count = h.checklist.replaceProjectItems(
        project.id,
        <String>['  一  ', '', '   ', '二', '二'],
      );

      expect(count, 3, reason: '空项丢掉；重复的「二」保留两条（去重是越权）');
      expect(h.itemTextsOnDisk(project.id), <String>['一', '二', '二']);
    });

    test('整体替换：全是空文本时拒绝，不动现有条目', () {
      final project = h.seedProject();
      h.checklist.addProjectItem(project.id, '原有的');

      expect(
        () => h.checklist.replaceProjectItems(project.id, <String>['', '  ']),
        throwsA(isA<RuleViolation>()),
      );
      expect(h.itemTextsOnDisk(project.id), <String>['原有的']);
    });
  });

  group('清空', () {
    test('清空只清清单，不动正文', () {
      final project = h.seedProject();
      h.seedImplementation(project.id, '正文要留着');
      h.checklist.addProjectItem(project.id, '一条');

      h.checklist.clearProjectItems(project.id);

      expect(h.itemsInMemory(project.id), isEmpty);
      expect(h.find(project.id)!.implementation, '正文要留着');
    });

    test('清单本来就空时**不落盘**（这一条是刻意保留的守卫）', () {
      final project = h.seedProject();
      final before = h.storeMtime();
      h.sleepPastFilesystemTimestamp();

      h.checklist.clearProjectItems(project.id);

      expect(
        h.storeMtime(),
        before,
        reason: '空清单上点"清空"不该写一次盘、白轮转一次备份',
      );
    });
  });

  group('边界与错误', () {
    test('项目不存在 / 已删除：一律抛，不做无声的空操作', () {
      expect(
        () => h.checklist.addProjectItem('not-a-project', 'x'),
        throwsA(isA<RuleViolation>()),
      );

      final project = h.seedProject();
      // "已删除"要比对的就是 `deleted == true` 那一个判据，所以直接改状态。
      h.state.upsert(
        DocName.projects,
        h.find(project.id)!.copyWith(deleted: true),
      );
      expect(
        () => h.checklist.addProjectItem(project.id, 'x'),
        throwsA(isA<RuleViolation>()),
        reason: '已删除的项目不算"存在"',
      );
    });

    test('建成任务：只读条目的文本，条目本身一个字都不动、也不自动打勾', () {
      final project = h.seedProject();
      h.seedImplementation(project.id, '- 清单里这句话');
      h.checklist.splitImplementationIntoItems(project.id);
      final item = h.itemsInMemory(project.id).single;
      final event = h.seedEvent('一条事件线');

      h.checklist.createTaskFromProjectItem(
        projectId: project.id,
        itemId: item.id,
        eventId: event.id,
        createTask: h.createTaskStub,
      );

      expect(h.createTaskCalls.length, 1, reason: '回调应当被调且只调一次');
      expect(
        h.lastCreateTaskCall.title,
        '清单里这句话',
        reason: '交给任务的标题就是条目的文本 —— 这是清单块对任务侧唯一的输出',
      );
      expect(h.lastCreateTaskCall.eventId, event.id, reason: 'eventId 原样透传，不自己选事件');
      // 清单这边一个字都没动
      expect(h.itemTextsOnDisk(project.id), <String>['清单里这句话']);
      expect(h.itemsInMemory(project.id).single.done, isFalse, reason: '不自动打勾');
      expect(h.itemsInMemory(project.id).single.id, item.id);
    });

    test('建成任务：条目不存在时抛，连回调都不该被调到', () {
      final project = h.seedProject();
      final event = h.seedEvent('一条事件线');

      var calls = 0;
      expect(
        () => h.checklist.createTaskFromProjectItem(
          projectId: project.id,
          itemId: 'not-an-item',
          eventId: event.id,
          createTask: ({required String eventId, required String title}) {
            calls += 1;
            return h.createTaskStub(eventId: eventId, title: title);
          },
        ),
        throwsA(isA<RuleViolation>()),
      );
      expect(calls, 0, reason: '抛在查条目那一步，根本走不到建任务');
    });

    test('两个公开助手：查项目与查下标，各自给出能读懂的原因', () {
      final project = h.seedProject();
      final item = h.checklist.addProjectItem(project.id, '一条');

      expect(h.checklist.requireProject(project.id).id, project.id);
      expect(h.checklist.itemIndex(h.find(project.id)!, item.id), 0);
      expect(
        () => h.checklist.requireProject('not-a-project'),
        throwsA(isA<RuleViolation>()),
      );
      expect(
        () => h.checklist.itemIndex(h.find(project.id)!, 'not-an-item'),
        throwsA(isA<RuleViolation>()),
      );
    });
  });
}

/// 这份文件的脚手架：把"清单块 + 它自己那份状态"接起来。
///
/// ## 为什么要有它
///
/// `WorkspaceChecklist` 要两样东西：一份 `WorkspaceState`，和一个
/// `(String) -> Project?` 的查项目函数。测试里必须让**两者指向同一份状态** ——
/// 否则"清单改完、按 id 再查回来"会读到另一份文档里的旧值，用例会莫名其妙地红。
/// 用子句（闭包）做不到这一点：`setUp` 里的变量在闭包声明之前就要求值。
/// 所以收成一个对象。
///
/// ## 它为什么还要一个 `Workspace`（门面）
///
/// 只用来**造数据的默认值**。`createProject` / `createEvent` 会算好 `order`、
/// 标志色、时间戳这些字段 —— 把 `Project` 手写一遍就是把这些默认值抄进测试，
/// 抄错了测试反而在替实现背书。
///
/// ⚠️ 两边的文档 Map 是**各自一份**。所以规矩是：
/// **造数据用 `_facade`，改与读一律用 `state` / `checklist`。**
/// 混着读会拿到另一份状态里的旧值。
class _Harness {
  _Harness() {
    _dir = Directory.systemTemp.createTempSync('guideline_checklist_');
    _storage = AppStorage(AppPaths(_dir!));
    // 与线上启动路径完全一致：先 load() 拿到 LoadReport，再各建各的
    final report = _storage.load();
    _facade = Workspace.fromLoad(_storage, report);
    state = WorkspaceState(
      storage: _storage,
      documents: <DocName, Document>{
        for (final name in DocName.values) name: report.store.documentOf(name),
      },
      prefs: report.prefs,
    );
    checklist = WorkspaceChecklist(state, find);
  }

  late final Directory? _dir;
  late final AppStorage _storage;
  late final Workspace _facade;

  /// 清单块自己那份状态。测试里读/改都走它。
  late final WorkspaceState state;

  /// **被测试的对象**：所有用例都直接调它，不经过门面转发。
  late final WorkspaceChecklist checklist;

  void dispose() {
    final dir = _dir;
    if (dir != null && dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// 从清单自己那份状态里查项目 —— 与交给 [checklist] 的查找函数是同一个。
  Project? find(String id) => state
      .documentOf(DocName.projects)
      .projectItems
      .where((p) => p.id == id && !p.deleted)
      .firstOrNull;

  /// 造一个项目：走门面拿默认值，再原样放进清单那份状态（同一个 id、同一批字段）。
  Project seedProject({String title = '目标'}) {
    final created = _facade.createProject(title: title);
    state.upsert(DocName.projects, created);
    return created;
  }

  /// 造一条事件，**在清单那份状态上直接造、不走门面**。
  ///
  /// 为什么不能"用门面造完再 upsert 进来"：`createEvent` 内部会落盘，
  /// 而门面持有的是**它自己那份空文档** —— 它一写盘，就把磁盘上刚从清单块
  /// 落下来的项目条目整份覆盖掉了。这条弯路我踩过一次，表现是
  /// "建成任务"那条用例在磁盘上读到空清单。
  ///
  /// 事件字段少、默认值都是常量，直接构造不构成"把实现抄进测试"。
  Event seedEvent(String name) {
    final now = Ids.nowMillis();
    final event = Event(
      id: Ids.uuidV4(),
      name: name,
      status: NodeStatus.pending,
      archived: false,
      order: orderStep,
      completedAt: null,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    state.upsert(DocName.events, event);
    return event;
  }

  /// 把某个项目的正文改成这段文字（造"正文可拆"的前置条件用）。
  void seedImplementation(String projectId, String implementation) {
    state.upsert(
      DocName.projects,
      find(projectId)!.copyWith(implementation: implementation),
    );
  }

  /// 清单块唯一伸向任务侧那根手指：`createTaskFromProjectItem` 收的回调。
  ///
  /// **不真的建任务**：本文件测的是清单块 —— 它只需要知道"这个回调被调用了、
  /// 收到的 eventId 与 title 是什么"。真去建任务会让 `Workspace.createTask` 落盘，
  /// 而门面持有的是它自己那份文档，一写就把磁盘上刚落的清单覆盖掉。
  /// 任务侧的正确性由 `workspace_test.dart` 与 `task_*` 那批用例负责。
  ///
  /// 返回一个**桩任务**，只为让回调满足 `createTaskFromProjectItem` 的签名；
  /// 用例不该拿它的字段当断言目标（那是桩的值，不是被实现算出来的值）。
  final List<({String eventId, String title})> createTaskCalls =
      <({String eventId, String title})>[];

  Task createTaskStub({required String eventId, required String title}) {
    createTaskCalls.add((eventId: eventId, title: title));
    return Task(
      id: 'stub-task',
      eventId: eventId,
      parentTaskId: null,
      taskType: TaskType.standard,
      title: title,
      dueAt: null,
      status: NodeStatus.pending,
      archived: false,
      order: orderStep,
      completedAt: null,
      createdAt: 0,
      updatedAt: 0,
      deleted: false,
    );
  }

  /// 最近一次回调收到的参数。
  ({String eventId, String title}) get lastCreateTaskCall => createTaskCalls.last;

  /// 内存里某个项目的清单条目 —— 从清单那份状态读。
  List<ProjectItem> itemsInMemory(String projectId) => find(projectId)!.items;

  /// 主数据文件在磁盘上的原始文本。
  String storeTextOnDisk() =>
      _storage.paths.storeFile.readAsStringSync(encoding: utf8);

  /// 主数据文件的最后修改时刻 —— 用来判"这一笔到底写盘了没有"。
  DateTime storeMtime() => _storage.paths.storeFile.lastModifiedSync();

  /// 让下一次写盘的时间戳能与上一次区分开。
  ///
  /// 文件系统的 mtime 精度可能只有秒级；两条"不该写盘"的用例靠 mtime 判断，
  /// 中间不隔一下的话，写与不写会得到同一个时间戳，用例会变成恒真。
  void sleepPastFilesystemTimestamp() =>
      sleep(const Duration(milliseconds: 1100));

  /// 从**磁盘**读某个项目的清单条目。
  ///
  /// **刻意从磁盘读、不从内存读**：这一块最危险的退化是"改了内存却没落盘"，
  /// 只断言内存会让那种退化全绿。
  List<String> itemTextsOnDisk(String projectId) {
    final store = StoreFile.parse(storeTextOnDisk(), DecodeIssues());
    for (final project in store.documents[DocName.projects]!.projectItems) {
      if (project.id == projectId) {
        return project.items.map((i) => i.text).toList(growable: false);
      }
    }
    return const <String>[];
  }
}
