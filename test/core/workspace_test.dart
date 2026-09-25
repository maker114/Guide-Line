import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/project_item.dart';
import 'package:guideline/core/models/project_palette.dart';
import 'package:guideline/core/rules/archive_zone.dart';
import 'package:guideline/core/rules/completion.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/features/workspace.dart';

/// 业务逻辑层（`Workspace`）测试 —— 由归档的电脑端工程移植到**手机单机版**。
///
/// 移植原则：
///   · 实体模型与业务规则与归档版一致 → 断言逐条保留，中文用例名不变；
///   · 云端同步 / 待完成事务（`version`、`pending_tx`、`dirty`、`markSynced`、
///     `applyRemoteDocument`、`SyncBackend`）在单机版已随代码删除 → 相关用例不再移植；
///   · 构造方式改为 `Workspace.fromLoad(AppStorage, LoadReport)`，每个用例一个临时目录；
///   · 落盘只有一份 `guideline.json`：**每次业务变更立刻原子写入**，
///     所以「改动马上能在磁盘上看到」和「第二次保存前有备份」本身就是要守住的行为。
void main() {
  late Directory dir;
  late AppStorage storage;
  late Workspace ws;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_ws_');
    storage = AppStorage(AppPaths(dir));
    // 与线上启动路径完全一致：先 load() 拿到 LoadReport，再由它构造 Workspace
    ws = Workspace.fromLoad(storage, storage.load());
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 主数据文件（`guideline.json`）的原始文本。
  String storeTextOnDisk() => storage.paths.storeFile.readAsStringSync(encoding: utf8);

  /// 把磁盘上的主数据文件按正式解析路径读回来（验证"写下去的确实能读回"）。
  StoreFile storeFileOnDisk() => StoreFile.parse(storeTextOnDisk(), DecodeIssues());

  group('项目：创建 / 层级 / 完成规则', () {
    test('可以建三层，第四层被拒绝', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      final grand = ws.createProject(title: '孙', parentId: child.id);

      expect(ws.projectTree.depthOf(grand.id), 3);
      expect(
        () => ws.createProject(title: '曾孙', parentId: grand.id),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('子项目未终态时父项目不可完成，并给出可读原因', () {
      final root = ws.createProject(title: '根');
      ws.createProject(title: '子', parentId: root.id);

      expect(() => ws.setProjectStatus(root.id, NodeStatus.done), throwsA(isA<RuleViolation>()));
      try {
        ws.setProjectStatus(root.id, NodeStatus.done);
      } on RuleViolation catch (violation) {
        expect(violation.message, contains('未处理'));
      }
    });

    test('归档与墓碑子项目不阻塞父项目完成（ADR-054 死锁修复）', () {
      final root = ws.createProject(title: '根');
      final archived = ws.createProject(title: '归档子', parentId: root.id);
      ws.setProjectArchived(archived.id, true);

      ws.setProjectStatus(root.id, NodeStatus.done);
      expect(ws.findProject(root.id)!.status, NodeStatus.done);
      expect(ws.findProject(root.id)!.completedAt, isNotNull);
    });

    test('反向传播：把子项目退回 pending，已完成的父项目自动退回（ADR-055）', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      ws.setProjectStatus(child.id, NodeStatus.done);
      ws.setProjectStatus(root.id, NodeStatus.done);
      expect(ws.findProject(root.id)!.status, NodeStatus.done);

      ws.setProjectStatus(child.id, NodeStatus.pending);

      expect(ws.findProject(child.id)!.status, NodeStatus.pending);
      expect(ws.findProject(root.id)!.status, NodeStatus.pending, reason: '硬约束必须恒真');
      expect(ws.findProject(root.id)!.completedAt, isNull);
    });

    test('ignore 是终态，可撤销', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      ws.setProjectStatus(child.id, NodeStatus.ignored);
      ws.setProjectStatus(root.id, NodeStatus.done);
      expect(ws.findProject(root.id)!.status, NodeStatus.done);
    });

    test('归档与取消归档双向级联（ADR-051）', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);

      ws.setProjectArchived(root.id, true);
      expect(ws.findProject(child.id)!.archived, isTrue);
      expect(ws.findProject(child.id)!.deleted, isFalse, reason: '归档不是删除');
      expect(ws.findProject(child.id)!.status, NodeStatus.pending, reason: '归档不改 status');

      ws.setProjectArchived(root.id, false);
      expect(ws.findProject(child.id)!.archived, isFalse);
    });

    test('移动：不能移入自身后代', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      expect(
        () => ws.updateProject(root.id, parentId: child.id),
        throwsA(isA<RuleViolation>()),
      );
    });
  });

  group('灵感：分配 / 合并 / 撤销 / 丢弃', () {
    test('合并 · 落点一（正文）：替换「实现计划」，灵感状态一起变（跨集合，天然原子）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('这条灵感要并进去');

      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '手写后的实现段落',
      );

      final merged = ws.findInspiration(inspiration.id)!;
      expect(merged.status, InspirationStatus.merged);
      expect(merged.mergedInto, project.id);
      expect(merged.deleted, isFalse, reason: '合并不用 deleted 表达');
      expect(merged.isConsistent, isTrue, reason: 'merged 必须同时有 merged_into / merged_at');
      expect(ws.findProject(project.id)!.implementation, '手写后的实现段落');
      expect(ws.findProject(project.id)!.items, isEmpty, reason: '走正文这一条就不动清单');

      // 跨集合改动要么一起落盘、要么一起没有（这是单文件存储要换来的性质）
      final onDisk = storeFileOnDisk();
      expect(
        onDisk.documentOf(DocName.projects).projectItems.single.implementation,
        '手写后的实现段落',
      );
      expect(
        onDisk.documentOf(DocName.inspirations).inspirationItems.single.status,
        InspirationStatus.merged,
      );
    });

    test('合并 · 落点二（清单条目）：追加成新的一条，正文一个字不动', () {
      final project = ws.createProject(title: '项目 B');
      ws.updateProject(project.id, implementation: '原来写好的计划');
      final inspiration = ws.captureInspiration('这条灵感要并进去');

      ws.mergeInspirationAsItem(
        inspirationId: inspiration.id,
        projectId: project.id,
        itemText: '手写后的条目',
      );

      final reloaded = ws.findProject(project.id)!;
      expect(reloaded.items.map((i) => i.text), <String>['手写后的条目']);
      expect(reloaded.items.single.done, isFalse, reason: '新条目不该是打勾的');
      expect(reloaded.implementation, '原来写好的计划', reason: '这一条不碰正文');
      expect(ws.findInspiration(inspiration.id)!.status, InspirationStatus.merged);
      expect(
        storeFileOnDisk().documentOf(DocName.projects).projectItems.single.items.single.text,
        '手写后的条目',
      );
    });

    test('两种落点都把空文本整条拒掉，且灵感不会变成已合并', () {
      final project = ws.createProject(title: '项目 C');
      final intoBody = ws.captureInspiration('并进正文');
      final intoItem = ws.captureInspiration('并进清单');

      expect(
        () => ws.mergeInspiration(
          inspirationId: intoBody.id,
          projectId: project.id,
          newImplementation: '   ',
        ),
        throwsA(isA<RuleViolation>()),
        reason: '空的合并结果不能把正文清没',
      );
      expect(
        () => ws.mergeInspirationAsItem(
          inspirationId: intoItem.id,
          projectId: project.id,
          itemText: '   ',
        ),
        throwsA(isA<RuleViolation>()),
      );

      expect(ws.findInspiration(intoBody.id)!.isPending, isTrue);
      expect(ws.findInspiration(intoItem.id)!.isPending, isTrue);
      expect(ws.findProject(project.id)!.implementation, isEmpty);
      expect(ws.findProject(project.id)!.items, isEmpty);
    });

    test('撤销合并只恢复灵感，正文与清单条目不回滚（ADR-057）', () {
      final project = ws.createProject(title: '项目 A');
      final intoBody = ws.captureInspiration('原文一');
      final intoItem = ws.captureInspiration('原文二');
      ws.mergeInspiration(
        inspirationId: intoBody.id,
        projectId: project.id,
        newImplementation: '用户编辑后的正文',
      );
      ws.mergeInspirationAsItem(
        inspirationId: intoItem.id,
        projectId: project.id,
        itemText: '用户编辑后的条目',
      );

      ws.undoMerge(intoBody.id);
      ws.undoMerge(intoItem.id);

      for (final id in <String>[intoBody.id, intoItem.id]) {
        final restored = ws.findInspiration(id)!;
        expect(restored.status, InspirationStatus.pending);
        expect(restored.mergedInto, isNull);
        expect(restored.projectId, project.id, reason: '项目还在 → 保留归属');
      }
      expect(ws.findProject(project.id)!.implementation, '用户编辑后的正文',
          reason: '正文不回滚');
      expect(
        ws.findProject(project.id)!.items.map((i) => i.text),
        <String>['用户编辑后的条目'],
        reason: '已经写进项目的内容不回滚 —— 与正文同一个口径',
      );
    });

    test('目标项目被彻底删除后，撤销合并会解除归属（悬挂引用）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('原文');
      ws.mergeInspiration(
        inspirationId: inspiration.id,
        projectId: project.id,
        newImplementation: '正文',
      );

      // 单机形态下没有"另一台设备整体替换文档"这回事，而 deleteProject 一定会把
      // merged 灵感一并解除归属（ADR-056），所以"灵感还是 merged、目标项目却已不在"
      // 只能由彻底删除（purge）直接抹掉项目来构造 —— 这正是 undoMerge 里
      // projectAlive 分支要兜住的情况，必须留用例守住。
      ws.purge(DocName.projects, <String>[project.id]);
      expect(ws.findProject(project.id), isNull, reason: '墓碑骨架不是 Project');

      ws.undoMerge(inspiration.id);

      final restored = ws.findInspiration(inspiration.id)!;
      expect(restored.status, InspirationStatus.pending);
      expect(restored.mergedInto, isNull);
      expect(restored.projectId, isNull, reason: '目标项目已不在 → 解除归属');
    });

    test('丢弃后进入归档区「已丢弃」，可恢复', () {
      final inspiration = ws.captureInspiration('待丢弃');
      ws.discardInspiration(inspiration.id);

      expect(ws.inspirationInbox, isEmpty);
      expect(ws.archiveZone.discardedInspirations.length, 1);

      ws.restoreInspiration(inspiration.id);
      expect(ws.inspirationInbox.length, 1);
    });

    test('已分配的 pending 灵感仍留在灵感列表（设计文档 4.12）', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('已分配未合并');
      ws.assignInspiration(inspiration.id, project.id);

      expect(ws.inspirationInbox.map((i) => i.id), contains(inspiration.id));
      expect(ws.findInspiration(inspiration.id)!.projectId, project.id);
    });
  });

  group('项目标志色自动分配', () {
    test('新建项目自动拿到一个色板里的颜色', () {
      final project = ws.createProject(title: '第一个');
      expect(project.color, isNotNull);
      expect(ProjectPalette.hexes, contains(project.color));
    });

    test('连续新建会**优先取还没用过的颜色**（同一层不撞色）', () {
      final colors = <String>[];
      for (var i = 0; i < 4; i += 1) {
        colors.add(ws.createProject(title: '项目$i').color!);
      }
      expect(colors.toSet().length, 4, reason: '前几个不该撞色');
    });

    test('删掉项目后它占的颜色会被让出来', () {
      final first = ws.createProject(title: '先建的');
      final firstColor = first.color!;
      ws.deleteProject(first.id);

      // 再建一个：因为原主被删了，"用得最少"应当把它挑回来
      final next = ws.createProject(title: '后建的');
      expect(next.color, firstColor, reason: '颜色分布应当自动均衡，删项目就把色让出来');
    });

    test('子项目也自动分配标志色', () {
      final root = ws.createProject(title: '根');
      final child = ws.createProject(title: '子', parentId: root.id);
      expect(child.color, isNotNull);
      expect(ProjectPalette.hexes, contains(child.color));
    });
  });

  group('事件标识色（与项目同一套系统）', () {
    test('新建事件自动拿到一个色板里的颜色，且前几条不撞色', () {
      final colors = <String>[];
      for (var i = 0; i < 4; i += 1) {
        colors.add(ws.createEvent(name: '事件$i').color!);
      }
      expect(colors.toSet().length, 4, reason: '前几个不该撞色');
      for (final color in colors) {
        expect(ProjectPalette.hexes, contains(color));
      }
    });

    test('事件与项目**各算各的**（同一份色板，互不干扰）', () {
      final project = ws.createProject(title: '项目');
      final event = ws.createEvent(name: '事件');
      expect(event.color, project.color, reason: '两边都从"用得最少"开始，第一支色相同');
      expect(ws.nextEventColor(), isNot(project.color), reason: '第二个事件要换一支');
    });

    test('设 / 清事件标识色：规范化小写，坏值拒绝，值没变不写盘', () {
      final event = ws.createEvent(name: '事件');

      ws.setEventColor(event.id, '#78D2CA');
      expect(ws.findEvent(event.id)!.color, '#78d2ca', reason: '统一成小写');

      expect(
        () => ws.setEventColor(event.id, '蓝色'),
        throwsA(isA<RuleViolation>()),
      );
      expect(ws.findEvent(event.id)!.color, '#78d2ca', reason: '被拒绝后保持原值');

      ws.setEventColor(event.id, null);
      expect(ws.findEvent(event.id)!.color, isNull, reason: '传 null 是"不用标识色"');

      // 清掉之后写盘里也不该再有这个字段（老数据逐字节一致的前提）
      final onDisk = storeFileOnDisk().documentOf(DocName.events).eventItems.single;
      expect(onDisk.color, isNull);
      expect(onDisk.toJson().containsKey('color'), isFalse, reason: 'null 不写出');
    });
  });

  group('灵感：改正文 / 一键追加 / 批量（灵感整理第 2、6、7 条）', () {
    test('改正文：改得掉、能落盘读回', () {
      final inspiration = ws.captureInspiration('原来的内容');
      ws.updateInspirationText(inspiration.id, '改过的内容');

      expect(ws.findInspiration(inspiration.id)!.text, '改过的内容');
      final reloaded = Workspace.fromLoad(storage, storage.load());
      expect(reloaded.findInspiration(inspiration.id)!.text, '改过的内容');
    });

    test('改正文：前后空格被去掉，空内容一律拒绝且保持原值', () {
      final inspiration = ws.captureInspiration('原文');
      ws.updateInspirationText(inspiration.id, '  带空格  ');
      expect(ws.findInspiration(inspiration.id)!.text, '带空格');

      for (final bad in <String>['', '   ', '\n\t ']) {
        expect(
          () => ws.updateInspirationText(inspiration.id, bad),
          throwsA(isA<RuleViolation>()),
          reason: '空内容不能把灵感清没',
        );
      }
      expect(ws.findInspiration(inspiration.id)!.text, '带空格', reason: '被拒绝后必须保持原值');
    });

    test('一键追加：原文原封不动作为新的一行接到正文末尾', () {
      expect(
        Workspace.appendToImplementation('一\n二', '三'),
        '一\n二\n三',
        reason: '非空正文先补一个换行',
      );
      expect(Workspace.appendToImplementation('', '三'), '三', reason: '空正文直接放');
      expect(
        Workspace.appendToImplementation('一\n\n', '三'),
        '一\n三',
        reason: '末尾多余空行要被收掉，不然会越接越散',
      );
      expect(Workspace.appendToImplementation('一', '  三  '), '一\n三');
      expect(Workspace.appendToImplementation('一', '   '), '一', reason: '空灵感什么也不加');
      // 关键：**不做任何润色或改写**，标点与换行都按原样
      const original = '带 - 破折号，还有「引号」\n第二行';
      expect(Workspace.appendToImplementation('', original), original);
    });

    test('一键追加走完整链路：合并后正文含原文，清单条目的文本也原样保留', () {
      final project = ws.createProject(title: '目标项目');
      final first = ws.captureInspiration('第一条灵感');
      ws.mergeInspiration(
        inspirationId: first.id,
        projectId: project.id,
        newImplementation: Workspace.appendToImplementation(
          ws.findProject(project.id)!.implementation,
          ws.findInspiration(first.id)!.text,
        ),
      );
      final second = ws.captureInspiration('第二条灵感');
      ws.mergeInspiration(
        inspirationId: second.id,
        projectId: project.id,
        newImplementation: Workspace.appendToImplementation(
          ws.findProject(project.id)!.implementation,
          ws.findInspiration(second.id)!.text,
        ),
      );

      expect(
        ws.findProject(project.id)!.implementation,
        '第一条灵感\n第二条灵感',
        reason: '两条各占一行、顺序是合并顺序',
      );
      expect(ws.inspirationInbox, isEmpty);
      expect(ws.archiveZone.mergedInspirations.length, 2);

      // 另一条落点：文本只 trim 首尾，其余一个字都不改
      const original = '带 - 破折号，还有「引号」\n第二行';
      final third = ws.captureInspiration('第三条灵感');
      ws.mergeInspirationAsItem(
        inspirationId: third.id,
        projectId: project.id,
        itemText: original,
      );
      expect(ws.findProject(project.id)!.items.single.text, original);
    });

    test('连续把两条灵感追加成清单条目：顺序就是合并顺序', () {
      final project = ws.createProject(title: '目标项目');
      final first = ws.captureInspiration('第一条灵感');
      ws.mergeInspirationAsItem(
        inspirationId: first.id,
        projectId: project.id,
        itemText: ws.findInspiration(first.id)!.text,
      );
      final second = ws.captureInspiration('第二条灵感');
      ws.mergeInspirationAsItem(
        inspirationId: second.id,
        projectId: project.id,
        itemText: ws.findInspiration(second.id)!.text,
      );

      final items = ws.findProject(project.id)!.items;
      expect(items.map((i) => i.text), <String>['第一条灵感', '第二条灵感']);
      expect(items.every((i) => !i.done), isTrue);
      expect(ws.inspirationInbox, isEmpty);
      expect(ws.archiveZone.mergedInspirations.length, 2);

      ws.undoMerge(second.id);
      expect(ws.findInspiration(second.id)!.isPending, isTrue);
      expect(
        ws.findProject(project.id)!.items.map((i) => i.text),
        <String>['第一条灵感', '第二条灵感'],
        reason: '撤销合并只恢复灵感，不回滚已经追加的条目（ADR-057）',
      );
    });

    test('批量分配：一次落盘，全部生效', () {
      final project = ws.createProject(title: '项目 A');
      final ids = <String>[
        ws.captureInspiration('一').id,
        ws.captureInspiration('二').id,
        ws.captureInspiration('三').id,
      ];

      ws.assignInspirations(ids, project.id);
      for (final id in ids) {
        expect(ws.findInspiration(id)!.projectId, project.id);
      }
      final reloaded = Workspace.fromLoad(storage, storage.load());
      expect(
        reloaded.liveInspirations.where((i) => i.projectId == project.id).length,
        3,
        reason: '批量结果要真的落盘',
      );
    });

    test('批量分配：其中一条已合并 → 整体拒绝，一条都不动', () {
      final project = ws.createProject(title: '项目 A');
      final ok = ws.captureInspiration('能分配的');
      final merged = ws.captureInspiration('已合并的');
      ws.mergeInspiration(
        inspirationId: merged.id,
        projectId: project.id,
        newImplementation: '已合并的',
      );

      expect(
        () => ws.assignInspirations(<String>[ok.id, merged.id], project.id),
        throwsA(isA<RuleViolation>()),
      );
      expect(
        ws.findInspiration(ok.id)!.projectId,
        isNull,
        reason: '批量要么全成、要么全不动，不能留下半截状态',
      );
    });

    test('批量分配空列表是安全的空操作', () {
      expect(() => ws.assignInspirations(const <String>[], null), returnsNormally);
    });

    test('批量丢弃 / 批量删除：各进各的状态', () {      final ids = <String>[
        ws.captureInspiration('丢弃一').id,
        ws.captureInspiration('丢弃二').id,
      ];
      ws.discardInspirations(ids);
      expect(ws.inspirationInbox, isEmpty);
      expect(ws.archiveZone.discardedInspirations.length, 2);
      expect(ws.archiveZone.discardedInspirations.every((i) => !i.deleted), isTrue);

      final deleted = <String>[
        ws.captureInspiration('删一').id,
        ws.captureInspiration('删二').id,
      ];
      ws.deleteInspirations(deleted);
      expect(ws.inspirationInbox.length, 0);
      // 注意：**回收站只装项目 / 事件 / 任务**（三种带层级的节点）。
      // 灵感是扁平实体，删除就是立墓碑、不再出现在任何分区里 ——
      // 所以这里断言的是"真的置了墓碑"，而不是"进了回收站"。
      for (final id in deleted) {
        expect(ws.findInspiration(id)!.deleted, isTrue);
      }
      expect(
        ws.liveInspirations.where((i) => deleted.contains(i.id)),
        isEmpty,
        reason: '删掉的灵感不能还留在实时列表里',
      );
      expect(ws.archiveZone.trashRoots, isEmpty, reason: '灵感不进回收站，这是既有约定');
    });

    test('改标签：清洗口径与契约一致（去空格、丢空串、按顺序去重），且能落盘', () {
      final inspiration = ws.captureInspiration('带标签的灵感');
      ws.updateInspirationTags(inspiration.id, <String>['  工作  ', '', '工作', '生活']);

      expect(
        ws.findInspiration(inspiration.id)!.tags,
        <String>['工作', '生活'],
        reason: 'trim、丢空串、去重（保留首次出现的顺序）',
      );

      final reloaded = Workspace.fromLoad(storage, storage.load());
      expect(reloaded.findInspiration(inspiration.id)!.tags, <String>['工作', '生活']);
    });

    test('改标签：清空是允许的，会回到"没有标签"', () {
      final inspiration = ws.captureInspiration('先有标签');
      ws.updateInspirationTags(inspiration.id, <String>['甲']);
      ws.updateInspirationTags(inspiration.id, const <String>[]);
      expect(ws.findInspiration(inspiration.id)!.tags, isEmpty);
    });

    test('项目标识色：只收 #rrggbb，存的是小写；非法值直接拒绝', () {
      final project = ws.createProject(title: '要上色的项目');

      ws.setProjectColor(project.id, '#2F6FEB');
      expect(ws.findProject(project.id)!.color, '#2f6feb', reason: '统一成小写');

      expect(
        () => ws.setProjectColor(project.id, '蓝色'),
        throwsA(isA<RuleViolation>()),
        reason: '非法色值要拒绝，不能在库里留下读不出来的值',
      );
      expect(ws.findProject(project.id)!.color, '#2f6feb', reason: '被拒绝后保持原值');

      ws.setProjectColor(project.id, null);
      expect(ws.findProject(project.id)!.color, isNull, reason: '传 null 是清空');

      final reloaded = Workspace.fromLoad(storage, storage.load());
      expect(reloaded.findProject(project.id)!.color, isNull);
    });
  });

  group('实现清单（设计文档 §1.4）', () {
    late Project project;

    setUp(() {
      project = ws.createProject(title: '带清单的项目');
    });

    List<ProjectItem> itemsOf() => ws.findProject(project.id)!.items;
    List<String> textsOf() => itemsOf().map((i) => i.text).toList();

    test('加条目：追加在末尾、默认未勾选，并立刻落盘', () {
      ws.addProjectItem(project.id, '第一条');
      ws.addProjectItem(project.id, '  第二条  ');

      expect(textsOf(), <String>['第一条', '第二条'], reason: '顺序就是加入顺序，且要 trim');
      expect(itemsOf().every((i) => !i.done), isTrue);
      expect(
        Workspace.fromLoad(storage, storage.load()).findProject(project.id)!.items.length,
        2,
        reason: '要真的写进磁盘',
      );
    });

    test('空内容一律拒绝，且不会留下空条目', () {
      for (final bad in <String>['', '   ', '\n\t']) {
        expect(
          () => ws.addProjectItem(project.id, bad),
          throwsA(isA<RuleViolation>()),
        );
      }
      expect(itemsOf(), isEmpty);
    });

    test('改条目文字：改得掉；空内容拒绝并保持原值；值没变不产生新时间戳', () {
      final item = ws.addProjectItem(project.id, '原文');
      ws.updateProjectItemText(project.id, item.id, '  改过  ');
      expect(itemsOf().single.text, '改过');

      expect(
        () => ws.updateProjectItemText(project.id, item.id, '   '),
        throwsA(isA<RuleViolation>()),
      );
      expect(itemsOf().single.text, '改过', reason: '被拒绝后保持原值');

      final before = ws.findProject(project.id)!.updatedAt;
      ws.updateProjectItemText(project.id, item.id, '改过');
      expect(ws.findProject(project.id)!.updatedAt, before, reason: '值没变就不该写盘');
    });

    test('勾选 / 取消勾选：只动那一条，且**不影响项目状态**', () {
      final a = ws.addProjectItem(project.id, '甲');
      final b = ws.addProjectItem(project.id, '乙');

      ws.setProjectItemDone(project.id, a.id, true);
      expect(itemsOf()[0].done, isTrue);
      expect(itemsOf()[1].done, isFalse, reason: '只该动被点的那一条');
      expect(ws.findProject(project.id)!.itemsDoneCount, 1);

      ws.setProjectItemDone(project.id, b.id, true);
      expect(ws.findProject(project.id)!.itemsDoneCount, 2);
      expect(
        ws.findProject(project.id)!.status,
        NodeStatus.pending,
        reason: '清单全勾完也不该把项目变成已完成 —— 清单不参与判定',
      );
    });

    test('删条目：只删指定那条；不存在的 id 会抛而不是静默', () {
      final a = ws.addProjectItem(project.id, '甲');
      final b = ws.addProjectItem(project.id, '乙');

      ws.removeProjectItem(project.id, a.id);
      expect(textsOf(), <String>['乙']);
      expect(() => ws.removeProjectItem(project.id, '不存在的-id'), throwsA(isA<RuleViolation>()));
      expect(textsOf(), <String>['乙'], reason: '失败不能改动清单');
      expect(b.id, isNotEmpty);
    });

    test('上移 / 下移：换位正确，到两端是空操作', () {
      ws.addProjectItem(project.id, '甲');
      final b = ws.addProjectItem(project.id, '乙');
      final c = ws.addProjectItem(project.id, '丙');

      ws.moveProjectItem(project.id, c.id, -1);
      expect(textsOf(), <String>['甲', '丙', '乙']);

      ws.moveProjectItem(project.id, c.id, -1);
      expect(textsOf(), <String>['丙', '甲', '乙']);

      ws.moveProjectItem(project.id, c.id, -1); // already first
      expect(textsOf(), <String>['丙', '甲', '乙'], reason: '到顶了就不动');

      ws.moveProjectItem(project.id, b.id, 1); // already last
      expect(textsOf(), <String>['丙', '甲', '乙'], reason: '到底了就不动');

      expect(
        () => ws.moveProjectItem(project.id, b.id, 2),
        throwsA(isA<RuleViolation>()),
        reason: '一次只允许一位',
      );
    });

    test('从正文拆条目：按行拆、去掉列表记号、丢空行', () {
      expect(
        Workspace.splitImplementationLines(
          '先冻结契约\n- 补齐样本\n* 写解析层\n1. 处理坏数据\n\n   \n2) 收尾',
        ),
        <String>['先冻结契约', '补齐样本', '写解析层', '处理坏数据', '收尾'],
      );
    });

    test('从正文拆条目：只在清单为空时允许，已有条目会被拒绝', () {
      final project2 = ws.createProject(title: '有正文没清单');
      ws.updateProject(project2.id, implementation: '第一步\n第二步');

      expect(ws.splitImplementationIntoItems(project2.id), 2);
      expect(
        ws.findProject(project2.id)!.items.map((i) => i.text),
        <String>['第一步', '第二步'],
      );

      expect(
        () => ws.splitImplementationIntoItems(project2.id),
        throwsA(isA<RuleViolation>()),
        reason: '已有条目再拆会把它们顶掉',
      );
    });

    test('从正文拆条目：正文为空时拒绝', () {
      final empty = ws.createProject(title: '空正文');
      expect(
        () => ws.splitImplementationIntoItems(empty.id),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('拆分之后正文**原样保留**（清单与正文是并存的两种形态）', () {
      final project3 = ws.createProject(title: '并存');
      ws.updateProject(project3.id, implementation: '第一步\n第二步');
      ws.splitImplementationIntoItems(project3.id);
      expect(
        ws.findProject(project3.id)!.implementation,
        '第一步\n第二步',
        reason: '拆是"另存一份结构"，不是"改写正文"',
      );
    });

    test('AI 整理写回正文：替换文本，清单不动', () {
      ws.addProjectItem(project.id, '甲');
      ws.addProjectItem(project.id, '乙');
      ws.replaceImplementation(project.id, '这是一段整理后的说明。');

      expect(ws.findProject(project.id)!.implementation, '这是一段整理后的说明。');
      expect(textsOf(), <String>['甲', '乙'], reason: '整理稿落回正文，清单保持原样');

      expect(
        () => ws.replaceImplementation(project.id, '   '),
        throwsA(isA<RuleViolation>()),
        reason: '空的整理结果不能把正文清没',
      );
      expect(ws.findProject(project.id)!.implementation, '这是一段整理后的说明。');
    });

    test('清单写入会落盘，重新加载后仍在（含勾选状态与顺序）', () {
      final a = ws.addProjectItem(project.id, '甲');
      ws.addProjectItem(project.id, '乙');
      ws.setProjectItemDone(project.id, a.id, true);

      final reloaded = Workspace.fromLoad(storage, storage.load()).findProject(project.id)!;
      expect(reloaded.items.map((i) => i.text), <String>['甲', '乙']);
      expect(reloaded.items.map((i) => i.done), <bool>[true, false]);
    });
  });

  group('删除项目的跨文档影响面（4.5 / ADR-056）', () {
    test('pending 灵感被删、merged 灵感回退为未分配，且一次落盘同时生效', () {
      final project = ws.createProject(title: '项目 A');
      final child = ws.createProject(title: '子项目', parentId: project.id);
      final assigned = ws.captureInspiration('分配给子项目', projectId: child.id);
      final mergedInspiration = ws.captureInspiration('将被合并');
      ws.mergeInspiration(
        inspirationId: mergedInspiration.id,
        projectId: child.id,
        newImplementation: '正文',
      );
      final unrelated = ws.captureInspiration('无关灵感');

      final plan = ws.deleteProject(project.id);

      expect(plan.projectIds.length, 2);
      expect(ws.findProject(project.id)!.deleted, isTrue);
      expect(ws.findProject(child.id)!.deleted, isTrue);
      expect(ws.findInspiration(assigned.id)!.deleted, isTrue);
      expect(ws.findInspiration(unrelated.id)!.deleted, isFalse);

      final reverted = ws.findInspiration(mergedInspiration.id)!;
      expect(reverted.status, InspirationStatus.pending, reason: '项目没了，内容要还回灵感列表');
      expect(reverted.projectId, isNull);
      expect(reverted.mergedInto, isNull);
      expect(reverted.deleted, isFalse);

      // 归档版这里断言的是"两份文档同时脏"（同步概念）；单机版改为直接核对磁盘：
      // 一次写入必须同时反映 projects 与 inspirations 的新状态。
      final onDisk = storeFileOnDisk();
      final projectOnDisk = onDisk
          .documentOf(DocName.projects)
          .projectItems
          .where((p) => p.id == project.id)
          .single;
      expect(projectOnDisk.deleted, isTrue);
      final revertedOnDisk = onDisk
          .documentOf(DocName.inspirations)
          .inspirationItems
          .where((i) => i.id == mergedInspiration.id)
          .single;
      expect(revertedOnDisk.status, InspirationStatus.pending);
      expect(revertedOnDisk.projectId, isNull);
    });
  });

  group('任务：结构约束 / 完成 / 移动', () {
    test('主线必须是标准任务，且父类型约束生效', () {
      final event = ws.createEvent(name: '事件 1');
      final standard = ws.createTask(eventId: event.id, title: '标准任务');
      final subtask = ws.createTask(
        eventId: event.id,
        title: '子任务',
        parentTaskId: standard.id,
        type: TaskType.subtask,
      );

      expect(subtask.parentId, standard.id);
      expect(
        () => ws.createTask(eventId: event.id, title: '非法', type: TaskType.parallel),
        throwsA(isA<RuleViolation>()),
        reason: '主线只能是标准任务',
      );
      expect(
        () => ws.createTask(eventId: event.id, title: '非法', parentTaskId: subtask.id, type: TaskType.subtask),
        throwsA(isA<RuleViolation>()),
        reason: '子任务是叶子',
      );
    });

    test('并列任务已废除：新建与改写都被拒绝，并指出替代做法', () {
      final event = ws.createEvent(name: '事件 1');
      final standard = ws.createTask(eventId: event.id, title: '标准任务');

      expect(
        () => ws.createTask(
          eventId: event.id,
          title: '并列',
          parentTaskId: standard.id,
          type: TaskType.parallel,
        ),
        throwsA(isA<RuleViolation>()),
        reason: '并列任务不能再新建出来',
      );
      expect(
        () => ws.updateTask(standard.id, taskType: TaskType.parallel),
        throwsA(isA<RuleViolation>()),
        reason: '也不能把已有的任务改写成并列',
      );
      // 拒绝的理由要说清"那该怎么办" —— 否则用户只会觉得这个功能坏了
      expect(
        () => ws.updateTask(standard.id, taskType: TaskType.parallel),
        throwsA(
          predicate<RuleViolation>((e) => e.message.contains('开两个「事件」')),
        ),
      );
      expect(TaskType.parallel.isCreatable, isFalse);
      expect(TaskType.subtask.isCreatable, isTrue);
    });

    test('老数据里的并列任务照旧读得进来，且不会被静默改写', () {
      // 手写一份"老文件"：主线 + 一条 parallel + 它自己的子任务
      final eventId = 'e0000000-0000-4000-8000-000000000001';
      final mainId = 'a0000000-0000-4000-8000-000000000001';
      final legacyId = 'a0000000-0000-4000-8000-000000000002';
      final leafId = 'a0000000-0000-4000-8000-000000000003';
      String taskJson(String id, String title, String type, String? parent) =>
          '{"id":"$id","event_id":"$eventId","parent_task_id":'
          '${parent == null ? 'null' : '"$parent"'},"next_task_ids":[],'
          '"task_type":"$type","title":"$title","due_at":null,"status":"pending",'
          '"archived":false,"order":1000,"completed_at":null,"created_at":1,'
          '"updated_at":1,"deleted":false}';
      File('${dir.path}${Platform.pathSeparator}guideline.json').writeAsStringSync(
        '{"schemaVersion":2,"savedAt":1,"collections":{'
        '"projects":{"items":[]},"inspirations":{"items":[]},'
        '"events":{"items":[{"id":"$eventId","name":"老事件","status":"pending",'
        '"archived":false,"order":1000,"completed_at":null,"created_at":1,'
        '"updated_at":1,"deleted":false}]},'
        '"tasks":{"items":['
        '${taskJson(mainId, '老主线', 'standard', null)},'
        '${taskJson(legacyId, '老并列', 'parallel', mainId)},'
        '${taskJson(leafId, '并列下的子任务', 'subtask', legacyId)}'
        ']}}}\n',
      );

      final loaded = Workspace.fromLoad(storage, storage.load());

      expect(loaded.findTask(legacyId)!.taskType, TaskType.parallel,
          reason: '枚举值不能删：删了这里就会被降级、下次保存被静默改写');
      expect(loaded.findTask(leafId)!.parentId, legacyId);
      expect(loaded.taskTree.depthOf(leafId), 3, reason: '它当年能挂子任务，现在照样成立');

      // 改状态也照常，且**写出后仍是 parallel**（不因"已废除"而迁移数据）
      loaded.setTaskStatus(leafId, NodeStatus.done);
      loaded.setTaskStatus(legacyId, NodeStatus.done);
      expect(
        File('${dir.path}${Platform.pathSeparator}guideline.json')
            .readAsStringSync()
            .contains('"task_type": "parallel"'),
        isTrue,
      );
    });

    test('链上的先后可以调：上移 / 下移 = 交换相邻两个节点的 order', () {
      final event = ws.createEvent(name: '事件 1');
      final a = ws.createTask(eventId: event.id, title: '第一');
      final b = ws.createTask(eventId: event.id, title: '第二');
      final c = ws.createTask(eventId: event.id, title: '第三');
      List<String> line() =>
          ws.mainLineOf(event.id).map((t) => t.title).toList(growable: false);

      expect(line(), <String>['第一', '第二', '第三']);

      ws.moveTaskWithinLine(c.id, up: true);
      expect(line(), <String>['第一', '第三', '第二']);

      // 已经在最前 / 最后就是空操作，不报错
      ws.moveTaskWithinLine(a.id, up: true);
      ws.moveTaskWithinLine(b.id, up: false);
      expect(line(), <String>['第一', '第三', '第二']);

      // 子任务不在链上，不参与顺序
      final sub = ws.createTask(
        eventId: event.id,
        title: '子任务',
        parentTaskId: b.id,
        type: TaskType.subtask,
      );
      expect(
        () => ws.moveTaskWithinLine(sub.id, up: true),
        throwsA(isA<RuleViolation>()),
      );
    });

    test('子任务未终态时父任务不可完成；完成后子任务退回会连带父任务退回', () {
      final event = ws.createEvent(name: '事件 1');
      final parent = ws.createTask(eventId: event.id, title: '父任务');
      final child = ws.createTask(
        eventId: event.id,
        title: '子任务',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );

      expect(() => ws.setTaskStatus(parent.id, NodeStatus.done), throwsA(isA<RuleViolation>()));
      ws.setTaskStatus(child.id, NodeStatus.done);
      ws.setTaskStatus(parent.id, NodeStatus.done);
      expect(ws.findTask(parent.id)!.status, NodeStatus.done);

      ws.setTaskStatus(child.id, NodeStatus.pending);
      expect(ws.findTask(parent.id)!.status, NodeStatus.pending);
    });

    test('跨事件移动任务时父引用归零', () {
      final eventA = ws.createEvent(name: '事件 A');
      final eventB = ws.createEvent(name: '事件 B');
      final parent = ws.createTask(eventId: eventA.id, title: '父');
      final child = ws.createTask(
        eventId: eventA.id,
        title: '子',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );

      ws.moveTask(child.id, newEventId: eventB.id, newParentTaskId: parent.id);

      final moved = ws.findTask(child.id)!;
      expect(moved.eventId, eventB.id);
      expect(moved.parentId, isNull, reason: '禁止跨事件父子');
    });

    test('删除任务级联子任务', () {
      final event = ws.createEvent(name: '事件 1');
      final parent = ws.createTask(eventId: event.id, title: '父');
      final child = ws.createTask(
        eventId: event.id,
        title: '子',
        parentTaskId: parent.id,
        type: TaskType.subtask,
      );

      final deleted = ws.deleteTask(parent.id);

      expect(deleted, <String>{parent.id, child.id});
      expect(ws.findTask(child.id)!.deleted, isTrue);
    });

    test('事件完成要求所有主线任务终态', () {
      final event = ws.createEvent(name: '事件 1');
      final first = ws.createTask(eventId: event.id, title: '任务 1');
      ws.createTask(eventId: event.id, title: '任务 2');

      expect(ws.checkEventCompletion(event.id).canComplete, isFalse);
      expect(() => ws.setEventStatus(event.id, NodeStatus.done), throwsA(isA<RuleViolation>()));

      ws.setTaskStatus(first.id, NodeStatus.done);
      // 让第二个任务也进入终态
      final second = ws.mainLineOf(event.id).firstWhere((t) => t.id != first.id);
      ws.setTaskStatus(second.id, NodeStatus.ignored);

      ws.setEventStatus(event.id, NodeStatus.done);
      expect(ws.findEvent(event.id)!.status, NodeStatus.done);
    });

    test('任务退回 pending 会连带把已完成的事件退回', () {
      final event = ws.createEvent(name: '事件 1');
      final task = ws.createTask(eventId: event.id, title: '任务');
      ws.setTaskStatus(task.id, NodeStatus.done);
      ws.setEventStatus(event.id, NodeStatus.done);

      ws.setTaskStatus(task.id, NodeStatus.pending);

      expect(ws.findEvent(event.id)!.status, NodeStatus.pending);
    });

    test('归档事件会级联整条任务线（跨集合）', () {
      final event = ws.createEvent(name: '事件 1');
      final task = ws.createTask(eventId: event.id, title: '任务');

      ws.setEventArchived(event.id, true);

      expect(ws.findEvent(event.id)!.archived, isTrue);
      expect(ws.findTask(task.id)!.archived, isTrue);
    });
  });

  group('归档区 / 搜索 / 到期 / 彻底删除', () {
    test('已归档只列归档根，回收站只列级联根', () {
      final root = ws.createProject(title: '根');
      ws.createProject(title: '子', parentId: root.id);
      ws.setProjectArchived(root.id, true);

      final other = ws.createProject(title: '要删的');
      ws.createProject(title: '它的子', parentId: other.id);
      ws.deleteProject(other.id);

      final zone = ws.archiveZone;
      expect(zone.archivedRoots.map((e) => e.id).toList(), <String>[root.id]);
      expect(zone.trashRoots.map((e) => e.id).toList(), <String>[other.id]);
    });

    test('搜索排除归档与已删除，灵感只搜 pending', () {
      final project = ws.createProject(title: '知识库', purpose: '让灵感有归宿');
      final archived = ws.createProject(title: '知识库-归档副本');
      ws.setProjectArchived(archived.id, true);
      final inspiration = ws.captureInspiration('知识库的一条灵感');
      ws.discardInspiration(inspiration.id);

      final hits = ws.search('知识库');
      final ids = hits.map((h) => h.entity.id).toSet();

      expect(ids, contains(project.id));
      expect(ids, isNot(contains(archived.id)));
      expect(ids, isNot(contains(inspiration.id)), reason: 'discarded 不参与搜索');
    });

    test('到期聚合按日期升序，只含未完成未归档', () {
      final event = ws.createEvent(name: '事件');
      final overdue = ws.createTask(eventId: event.id, title: '逾期', dueAt: '2026-01-01');
      final soon = ws.createTask(eventId: event.id, title: '本周', dueAt: '2026-09-25');
      final far = ws.createTask(eventId: event.id, title: '很久以后', dueAt: '2027-01-01');
      ws.setTaskStatus(far.id, NodeStatus.done);

      final due = ws.tasksDueOnOrBefore('2026-09-30');

      expect(due.map((t) => t.id).toList(), <String>[overdue.id, soon.id]);
    });

    test('已搁置的事件不再计入「到期」（实机反馈：放下的东西不该继续催）', () {
      final dropped = ws.createEvent(name: '先不做了');
      final droppedTask =
          ws.createTask(eventId: dropped.id, title: '搁置线的任务', dueAt: '2026-01-01');
      final active = ws.createEvent(name: '在做的事');
      final activeTask =
          ws.createTask(eventId: active.id, title: '进行中线的任务', dueAt: '2026-01-01');

      // 搁置之前：两条都算到期
      expect(ws.tasksDueOnOrBefore('2026-09-30').length, 2);
      expect(ws.isEventMutedForDue(dropped.id), isFalse);

      ws.setEventStatus(dropped.id, NodeStatus.ignored);

      expect(ws.isEventMutedForDue(dropped.id), isTrue);
      expect(
        ws.tasksDueOnOrBefore('2026-09-30').map((t) => t.id).toList(),
        <String>[activeTask.id],
        reason: '事件搁置后，它下面的任务不再参与到期统计',
      );
      // 任务本身仍是"待处理"，只是不算到期 —— 不改变数据，只改统计口径
      expect(ws.findTask(droppedTask.id)!.status, NodeStatus.pending);
      expect(ws.liveTasks.length, 2, reason: '任务不该因为事件搁置而消失');
    });

    test('彻底删除 = 墓碑骨架化，只保留 3 个 key（ADR-052）', () {
      final project = ws.createProject(title: '要彻底删掉');
      ws.deleteProject(project.id);
      final ids = ws.purgeIdsFor(DocName.projects, project.id);

      ws.purge(DocName.projects, ids);

      final entity = ws.documentOf(DocName.projects).items.firstWhere((e) => e.id == project.id);
      expect(entity, isA<Tombstone>());
      expect(entity.toJson().keys.toList(), <String>['id', 'deleted', 'purged_at']);
      expect(entity.toJson().containsKey('title'), isFalse);
    });

    test('「全部排期」含所有排了期的任务，不受截止日限制', () {
      final event = ws.createEvent(name: '事件');
      final old = ws.createTask(eventId: event.id, title: '逾期', dueAt: '2026-01-01');
      final far = ws.createTask(eventId: event.id, title: '很久以后', dueAt: '2027-01-01');
      ws.createTask(eventId: event.id, title: '没排期');
      final done = ws.createTask(eventId: event.id, title: '做完了', dueAt: '2026-02-02');
      ws.setTaskStatus(done.id, NodeStatus.done);

      expect(
        ws.tasksScheduled().map((t) => t.id).toList(),
        <String>[old.id, far.id],
        reason: '所有排了期的待处理任务，按日期升序；没排期的与已完成的不算',
      );
      expect(ws.tasksDueOnOrBefore('2026-09-30').map((t) => t.id).toList(), <String>[old.id]);
    });

    test('启动清理：满 30 天才清，活着的与没到期的一条都不动', () {
      final stale = ws.createProject(title: '删了很久了');
      final fresh = ws.createProject(title: '刚删的');
      final alive = ws.createProject(title: '活得好好的');
      final staleInspiration = ws.captureInspiration('删了很久的灵感');
      final freshInspiration = ws.captureInspiration('刚删的灵感');
      ws.deleteProject(stale.id);
      ws.deleteProject(fresh.id);
      ws.deleteInspiration(staleInspiration.id);
      ws.deleteInspiration(freshInspiration.id);

      // 单机形态下没有别的办法造"40 天前删的"：直接改盘上那份文件的 `updated_at`，
      // 再按正式启动路径重新加载 —— 与真机上"放了一个多月"走的是同一条路。
      final staleAt = DateTime.now()
          .subtract(const Duration(days: trashRetentionDays + 10))
          .millisecondsSinceEpoch;
      final raw = jsonDecode(storeTextOnDisk()) as Map<String, dynamic>;
      final collections = raw['collections'] as Map<String, dynamic>;
      for (final name in <String>['projects', 'inspirations']) {
        final items = (collections[name] as Map<String, dynamic>)['items'] as List<dynamic>;
        for (final item in items.cast<Map<String, dynamic>>()) {
          if (item['id'] == stale.id || item['id'] == staleInspiration.id) {
            item['updated_at'] = staleAt;
          }
        }
      }
      storage.paths.storeFile.writeAsStringSync(jsonEncode(raw), encoding: utf8);
      final reloaded = Workspace.fromLoad(storage, storage.load());

      final purged = reloaded.purgeExpiredTrash();

      expect(purged, 2, reason: '一个项目 + 一条灵感（灵感不进回收站，但墓碑同样只留 30 天）');
      expect(reloaded.findProject(stale.id), isNull, reason: '骨架化之后不再是 Project');
      expect(reloaded.findInspiration(staleInspiration.id), isNull);
      expect(reloaded.findProject(fresh.id)!.deleted, isTrue, reason: '没到期的不清');
      expect(reloaded.findInspiration(freshInspiration.id)!.deleted, isTrue);
      expect(reloaded.findProject(alive.id)!.deleted, isFalse, reason: '活着的节点一个字不动');
    });
  });

  group('持久化（单文件：每次变更立刻原子落盘）', () {
    test('变更无需显式保存，磁盘上立刻就能看到', () {
      final project = ws.createProject(title: '立刻落盘');

      // 没有调用 persist() / snapshotNow()，主文件里就应该已经有这条记录
      final text = storeTextOnDisk();
      expect(text, contains(project.id));
      expect(text, contains('立刻落盘'));

      // 而且写下去的是一份完整可解析的文件，不是半截中间态
      final reloaded = Workspace.fromLoad(storage, storage.load());
      expect(reloaded.findProject(project.id)!.title, '立刻落盘');
    });

    test('第二次保存前，上一份数据已轮转进滚动备份', () {
      final first = ws.createProject(title: '第一版');
      expect(
        storage.paths.rollingBackup(1).existsSync(),
        isFalse,
        reason: '首次保存时磁盘上还没有旧文件可轮转',
      );

      final second = ws.createProject(title: '第二版');

      final backup1 = storage.paths.rollingBackup(1);
      expect(backup1.existsSync(), isTrue);
      final backedUp = StoreFile.parse(backup1.readAsStringSync(encoding: utf8), DecodeIssues());
      final backedUpIds =
          backedUp.documentOf(DocName.projects).projectItems.map((p) => p.id).toSet();
      expect(backedUpIds, contains(first.id));
      expect(backedUpIds, isNot(contains(second.id)), reason: 'backup.1 是最近一次保存之前的状态');
      expect(storeTextOnDisk(), contains(second.id));
    });

    test('snapshotNow 能强制落盘并轮转出备份（批量操作前的手动快照）', () {
      final project = ws.createProject(title: '项目 A');
      expect(storage.paths.rollingBackup(1).existsSync(), isFalse);

      ws.snapshotNow();

      // 注释里承诺"手动触发一次备份轮转"，那就必须有 backup.1 可回退
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue);
      expect(
        storeFileOnDisk().documentOf(DocName.projects).projectItems.single.id,
        project.id,
      );
    });

    test('persist 后重新加载，数据与视图偏好都在', () {
      final project = ws.createProject(title: '项目 A');
      final inspiration = ws.captureInspiration('灵感');
      ws.mergeInspirationAsItem(
        inspirationId: inspiration.id,
        projectId: project.id,
        itemText: '条目',
      );
      ws.setExpanded(project.id, expanded: false);
      ws.persist();

      final reloaded = Workspace.fromLoad(storage, storage.load());

      expect(reloaded.findProject(project.id)!.items.single.text, '条目');
      expect(reloaded.findInspiration(inspiration.id)!.status, InspirationStatus.merged);
      expect(reloaded.findInspiration(inspiration.id)!.mergedInto, project.id);
      expect(reloaded.prefs.isExpanded(project.id), isFalse);
    });
  });

  group('完成规则工具', () {
    test('isTerminal 只认 done / ignored', () {
      expect(isTerminal(NodeStatus.done), isTrue);
      expect(isTerminal(NodeStatus.ignored), isTrue);
      expect(isTerminal(NodeStatus.pending), isFalse);
    });
  });
}
