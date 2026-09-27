import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/event.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/core/store/merge.dart';

/// 合并导入的纯逻辑内核（原《修改计划总表》Q25，该文档已移出工作区；
/// 现行落点见 docs/决策索引.md §2.2）。
///
/// 合并最怕的不是"合错了"，而是**悄悄丢东西**：丢一条记录用户当场能看出来，
/// 丢一个墓碑却要等到下次合并"复活"了才发作。所以这里的用例重点在两处：
///   · 胜负判定的口径（较新的一方赢、**相等时本地赢**、墓碑按 `purged_at` 比）；
///   · 什么都不丢（对方独有的墓碑、未知字段、四个集合、可空字段形态）。
void main() {
  const int base = 1788652800000;
  const int now = 1800000000000;

  Project project(
    String id, {
    String title = '项目',
    int updatedAt = base,
    String? parentProjectId,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) =>
      Project(
        id: id,
        title: title,
        purpose: '目的',
        implementation: '实现',
        date: null,
        status: NodeStatus.pending,
        archived: false,
        parentProjectId: parentProjectId,
        order: 1000,
        completedAt: null,
        createdAt: base,
        updatedAt: updatedAt,
        deleted: false,
        extra: extra,
      );

  Inspiration inspiration(
    String id, {
    String text = '灵感',
    int updatedAt = base,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) =>
      Inspiration(
        id: id,
        text: text,
        projectId: null,
        status: InspirationStatus.pending,
        mergedInto: null,
        mergedAt: null,
        createdAt: base,
        updatedAt: updatedAt,
        deleted: false,
        extra: extra,
      );

  Event event(String id, {String name = '事件', int updatedAt = base}) => Event(
        id: id,
        name: name,
        status: NodeStatus.pending,
        archived: false,
        order: 1000,
        completedAt: null,
        createdAt: base,
        updatedAt: updatedAt,
        deleted: false,
      );

  Task task(
    String id, {
    required String eventId,
    String? parentTaskId,
    int updatedAt = base,
  }) =>
      Task(
        id: id,
        eventId: eventId,
        parentTaskId: parentTaskId,
        taskType: parentTaskId == null ? TaskType.standard : TaskType.subtask,
        title: '任务',
        dueAt: null,
        status: NodeStatus.pending,
        archived: false,
        order: 1000,
        completedAt: null,
        createdAt: base,
        updatedAt: updatedAt,
        deleted: false,
      );

  StoreFile store({
    List<Entity> projects = const <Entity>[],
    List<Entity> inspirations = const <Entity>[],
    List<Entity> events = const <Entity>[],
    List<Entity> tasks = const <Entity>[],
    int savedAt = base,
  }) =>
      StoreFile(
        savedAt: savedAt,
        documents: <DocName, Document>{
          DocName.projects: Document(name: DocName.projects, items: projects),
          DocName.inspirations: Document(name: DocName.inspirations, items: inspirations),
          DocName.events: Document(name: DocName.events, items: events),
          DocName.tasks: Document(name: DocName.tasks, items: tasks),
        },
      );

  List<Entity> itemsOf(StoreFile file, DocName name) => file.documentOf(name).items;

  group('逐集合并入', () {
    test('两边 id 不同时各自并入：本地在前，对方独有的接在后面', () {
      final current = store(projects: <Entity>[project('p1', title: '本地')]);
      final incoming = store(projects: <Entity>[project('p2', title: '对方')]);
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      final items = itemsOf(outcome.store, DocName.projects);
      expect(items.map((e) => e.id).toList(), <String>['p1', 'p2'],
          reason: '本地顺序不动，对方独有的追加在后面');
      expect(outcome.report.of(DocName.projects).added.length, 1);
      expect(outcome.report.of(DocName.projects).localOnly, 1);
      expect(outcome.report.hasChanges, isTrue);
    });

    test('同一 id 落在不同集合时互不影响（逐集合各合各的）', () {
      final current = store(
        projects: <Entity>[project('x1', title: '本地项目')],
        tasks: <Entity>[task('x1', eventId: 'e1')],
      );
      final incoming = store(
        projects: <Entity>[project('x1', title: '对方项目', updatedAt: base + 1000)],
        events: <Entity>[event('e1')],
      );
      final outcome = mergeStores(current, incoming, nowMillis: now);

      expect((_find(outcome, DocName.projects, 'x1')! as Project).title, '对方项目',
          reason: '项目按项目合');
      expect(itemsOf(outcome, DocName.tasks).length, 1, reason: '任务那边对方没有 x1，不动');
      expect(itemsOf(outcome, DocName.events).length, 1, reason: '事件是另一条合并线');
    });

    test('同 id 且对方 updatedAt 较新 → 覆盖本地', () {
      final current = store(projects: <Entity>[project('p1', title: '本地', updatedAt: base)]);
      final incoming = store(
        projects: <Entity>[project('p1', title: '对方', updatedAt: base + 1000)],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      expect((_find(outcome.store, DocName.projects, 'p1')! as Project).title, '对方');
      expect(outcome.report.of(DocName.projects).updated.length, 1);
      expect(outcome.report.of(DocName.projects).kept, isEmpty);
    });

    test('同 id 且本地较新 → 保留本地，对方那份丢掉', () {
      final current = store(
        projects: <Entity>[project('p1', title: '本地', updatedAt: base + 5000)],
      );
      final incoming = store(
        projects: <Entity>[project('p1', title: '对方', updatedAt: base + 1000)],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      expect((_find(outcome.store, DocName.projects, 'p1')! as Project).title, '本地');
      expect(outcome.report.of(DocName.projects).kept.length, 1);
      expect(outcome.report.of(DocName.projects).updated, isEmpty);
    });

    test('updatedAt 完全相等时保留当前库那一份（同一秒的抖动不换用户手上的记录）', () {
      final current = store(projects: <Entity>[project('p1', title: '本地', updatedAt: base)]);
      final incoming = store(projects: <Entity>[project('p1', title: '对方', updatedAt: base)]);
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      expect((_find(outcome.store, DocName.projects, 'p1')! as Project).title, '本地',
          reason: '相等时本地为准：宁可这次没并进来，也不要"看起来没变却换了内容"');
      expect(outcome.report.of(DocName.projects).kept.length, 1);
      expect(outcome.report.of(DocName.projects).updated, isEmpty);
    });
  });

  group('墓碑', () {
    test('对方的墓碑比本地活记录新 → 以墓碑为准（本地这条被删掉）', () {
      final current = store(projects: <Entity>[project('p1', updatedAt: base)]);
      final incoming = store(
        projects: <Entity>[const Tombstone(id: 'p1', purgedAt: base + 1000)],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      final merged = _find(outcome.store, DocName.projects, 'p1');
      expect(merged, isA<Tombstone>());
      expect(outcome.report.of(DocName.projects).tombstones.length, 1);
      expect(outcome.report.of(DocName.projects).updated, isEmpty,
          reason: '墓碑单独一类，不混进"更新"里');
    });

    test('本地活记录比对方的墓碑新 → 活记录留下（既不复活也不误删）', () {
      final current = store(
        projects: <Entity>[project('p1', title: '本地新的', updatedAt: base + 5000)],
      );
      final incoming = store(
        projects: <Entity>[const Tombstone(id: 'p1', purgedAt: base + 1000)],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      expect((_find(outcome.store, DocName.projects, 'p1')! as Project).title, '本地新的');
      expect(outcome.report.of(DocName.projects).tombstones, isEmpty);
      expect(outcome.report.of(DocName.projects).kept.length, 1);
    });

    test('本地墓碑比对方的活记录新 → 墓碑留下（删除不会被旧数据翻回去）', () {
      final current = store(
        projects: <Entity>[const Tombstone(id: 'p1', purgedAt: base + 5000)],
      );
      final incoming = store(
        projects: <Entity>[project('p1', title: '对方旧的', updatedAt: base + 1000)],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      expect(_find(outcome.store, DocName.projects, 'p1'), isA<Tombstone>());
      expect(outcome.report.of(DocName.projects).kept.length, 1);
    });

    test('对方独有的墓碑必须并入，不会被丢掉（丢了下次合并就会"复活"）', () {
      final current = store(projects: <Entity>[project('p1')]);
      final incoming = store(
        projects: <Entity>[const Tombstone(id: 'p9', purgedAt: base + 1000)],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      expect(_find(outcome.store, DocName.projects, 'p9'), isA<Tombstone>());
      expect(outcome.report.of(DocName.projects).tombstones.length, 1);
      expect(outcome.report.of(DocName.projects).added, isEmpty,
          reason: '并入的墓碑不算"新增"，否则界面会说多出来一条数据');

      // 落盘再读回来仍是墓碑骨架（三个 key、顺序固定）
      final reloaded = StoreFile.parse(outcome.store.toCanonicalText(), DecodeIssues());
      final skeleton = _find(reloaded, DocName.projects, 'p9');
      expect(skeleton, isA<Tombstone>());
      expect(
        (skeleton! as Tombstone).toJson().keys.toList(),
        <String>['id', 'deleted', 'purged_at'],
      );
    });

    test('双方都有墓碑时按 purged_at 取较新的那个', () {
      final current = store(
        projects: <Entity>[const Tombstone(id: 'p1', purgedAt: base + 1000)],
      );
      final incoming = store(
        projects: <Entity>[const Tombstone(id: 'p1', purgedAt: base + 2000)],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      expect((_find(outcome.store, DocName.projects, 'p1')! as Tombstone).purgedAt,
          base + 2000);
      expect(outcome.report.of(DocName.projects).tombstones.length, 1);
    });
  });

  group('契约形态', () {
    test('未知字段透传不丢（胜出/并入的记录带的额外键原样保留）', () {
      final current = store(
        projects: <Entity>[
          // p1 会被对方覆盖（本地那份的额外键跟着落败方一起走），
          // p2 是本地独有的，它的额外键必须一条不少地留下来。
          project('p1', title: '本地'),
          project('p2', title: '本地独有', extra: <String, dynamic>{'future_field': '本地预留'}),
        ],
        inspirations: <Entity>[
          inspiration('i1', extra: <String, dynamic>{'from_desktop': 42}),
        ],
      );
      final incoming = store(
        projects: <Entity>[
          project(
            'p1',
            title: '对方',
            updatedAt: base + 1000,
            extra: <String, dynamic>{'another_field': <String>['x']},
          ),
        ],
      );
      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);

      // 同 id 胜出的是一整条记录：`extra` 跟着它一起过来。**落败那一方的额外键
      // 不会并进来** —— 一条记录是原子的，拼一份"半新半旧"的记录比丢一个未知键
      // 更糟。（这条口径要不要改，属于要用户拍板的事，见回报。）
      expect((_find(outcome.store, DocName.projects, 'p1')! as Project).extra,
          <String, dynamic>{'another_field': <String>['x']});

      final text = outcome.store.toCanonicalText();
      expect(text.contains('future_field'), isTrue, reason: '本地独有那条的额外键还在');
      expect(text.contains('another_field'), isTrue);
      expect(text.contains('from_desktop'), isTrue);

      // 读回来也不丢
      final reloaded = StoreFile.parse(text, DecodeIssues());
      expect((_find(reloaded, DocName.projects, 'p1')! as Project).extra['another_field'],
          <String>['x']);
      expect(
        (_find(reloaded, DocName.projects, 'p2')! as Project).extra['future_field'],
        '本地预留',
      );
      expect(
        (_find(reloaded, DocName.inspirations, 'i1')! as Inspiration).extra['from_desktop'],
        42,
      );
    });

    test('可空字段写 null、"空即省略"沿用既有序列化（没有手拼 JSON）', () {
      final outcome = mergeStores(
        store(inspirations: <Entity>[inspiration('i1')]),
        store(projects: <Entity>[project('p1')]),
        nowMillis: now,
      );
      final text = outcome.toCanonicalText();

      expect(text.contains('"date": null'), isTrue);
      expect(text.contains('"completed_at": null'), isTrue);
      expect(text.contains('"color"'), isFalse, reason: '没有标识色就不写出这个 key');
      expect(text.contains('"tags"'), isFalse, reason: '空标签不写出这个 key');
      expect(text.contains('1.7886528e12'), isFalse, reason: '时间戳必须是整数形态');
    });

    test('合并结果能正常读回：四个集合齐全、条数与报告对得上（往返）', () {
      final current = store(
        projects: <Entity>[project('p1'), project('p2', updatedAt: base + 9000)],
        inspirations: <Entity>[inspiration('i1')],
        events: <Entity>[event('e1')],
        tasks: <Entity>[
          task('t1', eventId: 'e1'),
          task('t2', eventId: 'e1', parentTaskId: 't1', updatedAt: base + 1000),
        ],
      );
      final incoming = store(
        projects: <Entity>[
          project('p1', title: '对方覆盖', updatedAt: base + 5000),
          project('p3'),
          const Tombstone(id: 'p9', purgedAt: base + 100),
        ],
        inspirations: <Entity>[inspiration('i1', text: '对方旧的')],
        events: <Entity>[event('e2')],
        tasks: <Entity>[task('t2', eventId: 'e1', parentTaskId: 't1', updatedAt: base)],
      );

      final outcome = mergeStoresWithReport(current, incoming, nowMillis: now);
      expect(outcome.store.savedAt, now, reason: 'savedAt 用传入的 nowMillis');

      final issues = DecodeIssues();
      final reloaded = StoreFile.parse(outcome.store.toCanonicalText(), issues);

      expect(issues.errors, isEmpty);
      expect(issues.warnings, isEmpty);
      for (final name in DocName.values) {
        expect(
          itemsOf(reloaded, name).map((e) => e.id).toList(),
          itemsOf(outcome.store, name).map((e) => e.id).toList(),
          reason: '$name 往返后条数与顺序都应一致',
        );
        expect(
          itemsOf(outcome.store, name).length,
          outcome.report.of(name).total,
          reason: '$name 的四类计数之和应等于合并后的条数',
        );
      }

      // 外层结构：collections 下四个集合都在
      final root = json.decode(outcome.store.toCanonicalText()) as Map<String, dynamic>;
      final collections = root['collections'] as Map<String, dynamic>;
      expect(
        collections.keys.toSet(),
        <String>{'projects', 'inspirations', 'events', 'tasks'},
      );
      expect(root['schemaVersion'], StoreFile.currentSchemaVersion);
    });

    test('不改入参（纯函数）：合并前后两份输入的落盘文本逐字节不变', () {
      final current = store(projects: <Entity>[project('p1', title: '本地')]);
      final incoming = store(
        projects: <Entity>[
          project('p1', title: '对方', updatedAt: base + 1000),
          project('p2'),
        ],
      );
      final currentBefore = current.toCanonicalText();
      final incomingBefore = incoming.toCanonicalText();

      mergeStores(current, incoming, nowMillis: now);

      expect(current.toCanonicalText(), currentBefore);
      expect(incoming.toCanonicalText(), incomingBefore);
    });
  });

  group('报告', () {
    test('计数正确：新增 / 更新 / 保留 / 墓碑 各一类', () {
      final current = store(
        projects: <Entity>[
          project('p1', updatedAt: base), // 对方较新 → 更新
          project('p2', updatedAt: base + 9000), // 本地较新 → 保留
          project('p3'), // 本地独有
        ],
        events: <Entity>[event('e1')],
      );
      final incoming = store(
        projects: <Entity>[
          project('p1', updatedAt: base + 1000),
          project('p2', updatedAt: base),
          project('p4'), // 对方独有 → 新增
          const Tombstone(id: 'p5', purgedAt: base + 1000), // → 墓碑
        ],
      );

      final report = mergeStoresWithReport(current, incoming, nowMillis: now).report;
      final projects = report.of(DocName.projects);

      expect(projects.added.map((e) => e.id).toList(), <String>['p4']);
      expect(projects.updated.map((e) => e.id).toList(), <String>['p1']);
      expect(projects.kept.map((e) => e.id).toList(), <String>['p2']);
      expect(projects.tombstones.map((e) => e.id).toList(), <String>['p5']);
      expect(projects.localOnly, 1);
      expect(projects.total, 5, reason: '四类 + 本地独有 = 合并后的条数');

      expect(report.added, 1);
      expect(report.updated, 1);
      expect(report.kept, 1);
      expect(report.tombstones, 1);
      expect(report.localOnly, 2, reason: '四个集合加起来：项目里 1 条（p3）+ 事件里 1 条（e1）');
      expect(report.changeSummary, '新增 1 · 更新 1 · 保留 1 · 墓碑 1');

      // 事件集合这次没有对方数据：一条不少地留着，也不算变化
      expect(report.of(DocName.events).localOnly, 1);
      expect(report.of(DocName.events).hasChanges, isFalse);
    });

    test('引用悬挂只报数、不当场修（留给加载层按契约 §4.3 / §8 处理）', () {
      final current = store(
        projects: <Entity>[
          project('p1', parentProjectId: 'p-missing'),
          project('p2'),
          project('p3', parentProjectId: 'p2'),
        ],
        events: <Entity>[event('e1')],
        tasks: <Entity>[
          task('t1', eventId: 'e-missing'),
          task('t2', eventId: 'e1'),
        ],
      );
      final outcome = mergeStoresWithReport(current, store(), nowMillis: now);

      expect(outcome.report.danglingReferences, 2,
          reason: 'p1 指向缺失的父项目、t1 指向缺失的事件，各算一条');
      expect((_find(outcome.store, DocName.projects, 'p1')! as Project).parentProjectId,
          'p-missing',
          reason: '只报数，不把引用改成 null —— 那会不可逆地丢掉"它本来指向谁"');
    });

    test('同一份文件里同 id 重复只认第一条，并计入 duplicatesCollapsed', () {
      final current = store(
        projects: <Entity>[project('p1', title: '一'), project('p1', title: '二')],
      );
      final outcome = mergeStoresWithReport(current, store(), nowMillis: now);

      expect(itemsOf(outcome.store, DocName.projects).length, 1);
      expect((_find(outcome.store, DocName.projects, 'p1')! as Project).title, '一');
      expect(outcome.report.duplicatesCollapsed, 1);
    });
  });

  group('空数据', () {
    test('两边都是空文件：不崩、四集合齐全、报告为空', () {
      final outcome = mergeStoresWithReport(StoreFile.empty(), StoreFile.empty(), nowMillis: now);

      for (final name in DocName.values) {
        expect(itemsOf(outcome.store, name), isEmpty);
        expect(outcome.store.documents.containsKey(name), isTrue);
      }
      expect(outcome.report.hasChanges, isFalse);
      expect(outcome.report.danglingReferences, 0);
      expect(outcome.store.savedAt, now);
      expect(StoreFile.parse(outcome.store.toCanonicalText(), DecodeIssues()).documents.length,
          DocName.values.length);
    });

    test('只有一边有内容（两个方向都不崩，另一边原样留着）', () {
      final filled = store(
        projects: <Entity>[project('p1')],
        events: <Entity>[event('e1')],
        tasks: <Entity>[task('t1', eventId: 'e1')],
      );

      final forward = mergeStoresWithReport(filled, StoreFile.empty(), nowMillis: now);
      expect(itemsOf(forward.store, DocName.projects).length, 1);
      expect(itemsOf(forward.store, DocName.tasks).length, 1);
      expect(forward.report.hasChanges, isFalse, reason: '对方什么都没有，等于什么都没变');

      final backward = mergeStoresWithReport(StoreFile.empty(), filled, nowMillis: now);
      expect(itemsOf(backward.store, DocName.events).length, 1);
      expect(backward.report.added, 3);
      expect(backward.report.of(DocName.projects).localOnly, 0);
    });

    test('某一侧缺整个集合时，结果仍然四集合齐全（不写出半个库）', () {
      final onlyProjects = StoreFile(
        documents: <DocName, Document>{
          DocName.projects: Document(
            name: DocName.projects,
            items: <Entity>[project('p1')],
          ),
        },
        savedAt: base,
      );

      final outcome = mergeStores(onlyProjects, StoreFile.empty(), nowMillis: now);
      for (final name in DocName.values) {
        expect(outcome.documents.containsKey(name), isTrue, reason: '缺的集合按空处理');
      }
      expect(itemsOf(outcome, DocName.projects).length, 1);
      expect(outcome.toCanonicalText().contains('"inspirations"'), isTrue);
    });
  });
}

/// 按 id 取一条记录（找不到返回 `null`，用例里断言"该丢的真的没了"很方便）。
Entity? _find(StoreFile store, DocName name, String id) {
  for (final item in store.documentOf(name).items) {
    if (item.id == id) return item;
  }
  return null;
}
