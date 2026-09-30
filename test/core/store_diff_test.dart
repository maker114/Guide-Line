import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/store_diff.dart';

/// 版本差异是**给人看的**，所以这一层只守住两件事：
///   · 口径是 **git 式**的 —— 一处改动 = 红（上个版本）紧挨着绿（下个版本）一对；
///   · **"会不会把对面推没了一整条"** 与"同一条被顶掉"是两回事 ——
///     自动上传前靠 `dropsFromBase` 决定要不要弹面板，判错就会不打招呼地覆盖云端。
///
/// 2026-09-30 起（ADR-093，用户要求）改动那两行底下还要写清**改了什么**：
/// `describeFieldChanges` 报"字段：旧值 → 新值"，但不报 `updated_at` 这种
/// 必然跟着变的噪声键。
void main() {
  const int t1 = 1788652800000; // 2026-09-23 08:00 UTC

  Project project(
    String id, {
    String title = '指南线',
    String purpose = '目的',
    NodeStatus status = NodeStatus.pending,
    bool archived = false,
    bool deleted = false,
    int updatedAt = t1,
    int? completedAt,
  }) =>
      Project(
        id: id,
        title: title,
        purpose: purpose,
        implementation: '实现',
        date: '2026-09-23',
        status: status,
        archived: archived,
        parentProjectId: null,
        order: 1000,
        completedAt: completedAt,
        createdAt: t1,
        updatedAt: updatedAt,
        deleted: deleted,
      );

  Inspiration inspiration(
    String id, {
    String text = '想法',
    InspirationStatus status = InspirationStatus.pending,
    String? mergedInto,
    int? mergedAt,
  }) =>
      Inspiration(
        id: id,
        text: text,
        projectId: 'p1',
        status: status,
        mergedInto: mergedInto,
        mergedAt: mergedAt,
        createdAt: t1,
        updatedAt: t1,
        deleted: false,
      );

  StoreFile store(List<Project> projects, {List<Entity> tombstones = const <Entity>[]}) =>
      StoreFile(
        savedAt: t1,
        documents: <DocName, Document>{
          for (final name in DocName.values) name: Document.empty(name),
          DocName.projects:
              Document(name: DocName.projects, items: <Entity>[...projects, ...tombstones]),
        },
      );

  test('新增标绿、删除标红', () {
    final diff = diffStores(
      base: store(<Project>[project('p1', title: '留下的'), project('p2', title: '要删的')]),
      target: store(<Project>[project('p1', title: '留下的'), project('p3', title: '新来的')]),
    );

    final entries = diff.of(DocName.projects).entries;
    expect(entries.length, 2);
    expect(entries[0].label, '要删的');
    expect(entries[0].side, DiffSide.previous);
    expect(entries[0].kind, DiffKind.removed);
    expect(entries[1].label, '新来的');
    expect(entries[1].side, DiffSide.next);
    expect(entries[1].kind, DiffKind.added);
    expect(diff.removed, 1);
    expect(diff.added, 1);
    expect(diff.modified, 0);
    expect(diff.hasChanges, isTrue);
  });

  test('同一条记录内容变了 = 红旧紧挨着绿新，算"改动"而不是"丢了一整条"', () {
    final diff = diffStores(
      base: store(<Project>[project('p1', title: '旧名字')]),
      target: store(<Project>[project('p1', title: '新名字')]),
    );

    final entries = diff.of(DocName.projects).entries;
    expect(entries.length, 2, reason: '一处改动两行，和 git 一样');
    expect(entries[0].side, DiffSide.previous);
    expect(entries[0].label, '旧名字');
    expect(entries[1].side, DiffSide.next);
    expect(entries[1].label, '新名字');
    expect(entries[0].kind, DiffKind.modified);
    expect(entries[1].kind, DiffKind.modified);
    expect(diff.modified, 1, reason: '一对只算一处');
    expect(diff.removed, 0);
    expect(
      diff.dropsFromBase,
      isFalse,
      reason: '被本机版本顶掉 ≠ 云端整条没了 —— 自动上传的护栏只认后者',
    );
  });

  test('完成状态翻面照同一套规则走（改动即先删后增）', () {
    final diff = diffStores(
      base: store(<Project>[project('p1', status: NodeStatus.pending)]),
      target: store(<Project>[project('p1', status: NodeStatus.done)]),
    );

    final entries = diff.of(DocName.projects).entries;
    expect(entries.length, 2);
    expect(entries[0].side, DiffSide.previous);
    expect(entries[1].side, DiffSide.next);
    expect(diff.modified, 1);
  });

  test('只有真正消失的 id 才算"基准会丢掉东西"', () {
    final diff = diffStores(
      base: store(<Project>[project('p1'), project('p2')]),
      target: store(<Project>[project('p1')]),
    );

    expect(diff.dropsFromBase, isTrue);
    expect(diff.removed, 1);
    expect(diff.changeSummary, '新增 0 · 删除 1 · 修改 0');
  });

  test('两份一模一样时没有任何差异', () {
    final same = <Project>[project('p1'), project('p2', title: '另一个')];
    final diff = diffStores(base: store(same), target: store(same));

    expect(diff.hasChanges, isFalse);
    expect(diff.changed, isEmpty);
    expect(diff.dropsFromBase, isFalse);
  });

  test('墓碑算一条红的，名字如实写"已彻底删除"', () {
    final diff = diffStores(
      base: store(<Project>[], tombstones: <Entity>[const Tombstone(id: 'gone', purgedAt: t1)]),
      target: store(<Project>[]),
    );

    final entries = diff.of(DocName.projects).entries;
    expect(entries.length, 1);
    expect(entries.single.kind, DiffKind.removed);
    expect(entries.single.label, '已彻底删除');
  });

  test('排序：红绿成对在前，纯新增的追加在最后', () {
    final diff = diffStores(
      base: store(<Project>[
        project('p1', title: '改前'),
        project('p2', title: '留下'),
      ]),
      target: store(<Project>[
        project('p1', title: '改后'),
        project('p2', title: '留下'),
        project('p3', title: '新增'),
      ]),
    );

    expect(
      diff.of(DocName.projects).entries.map((e) => e.label).toList(),
      <String>['改前', '改后', '新增'],
    );
  });

  test('集合之间互不串门：项目变了不会写作灵感的差异', () {
    final diff = diffStores(
      base: store(<Project>[project('p1')]),
      target: store(<Project>[project('p1'), project('p2')]),
    );

    expect(diff.of(DocName.projects).added, 1);
    expect(diff.of(DocName.inspirations).hasChanges, isFalse);
    expect(diff.of(DocName.events).hasChanges, isFalse);
    expect(diff.of(DocName.tasks).hasChanges, isFalse);
  });

  group('改动说明（需求③：红绿那两行底下写清改了什么）', () {
    test('完成状态翻面：说出旧新两个说法', () {
      final changes = describeFieldChanges(
        project('p1'),
        project('p1', status: NodeStatus.done, completedAt: t1),
      );

      expect(changes.map((c) => c.key).toList(), <String>['completed_at', 'status']);
      expect(changes.last.text, '状态：未完成 → 已完成');
      expect(
        changes.first.text,
        matches(RegExp(r'^完成时间：空 → \d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
      );
    });

    test('updated_at 必然跟着变，不报它：只说真正改了的那个字段', () {
      final changes = describeFieldChanges(
        project('p1', title: '指南线'),
        project('p1', title: '改名了', updatedAt: t1 + 60000),
      );

      expect(changes.map((c) => c.key).toList(), <String>['title']);
      expect(changes.single.text, '标题：指南线 → 改名了');
    });

    test('取值写法：真假写「是/否」、没有写「空」、长文本截到 24 字', () {
      final long = List<String>.filled(25, '字').join();

      final flag = describeFieldChanges(
        project('p1', title: long),
        project('p1', title: long, archived: true),
      );
      expect(flag.single.text, '已归档：否 → 是');

      final clipped = describeFieldChanges(project('p1'), project('p1', title: long)).single;
      expect(clipped.after, '${List<String>.filled(24, '字').join()}…');
    });

    test('按键名排序：顺序稳定，不随字段声明顺序漂', () {
      final changes = describeFieldChanges(
        project('p1'),
        project('p1', title: '新名', purpose: '新目的', status: NodeStatus.ignored),
      );

      expect(changes.map((c) => c.key).toList(), <String>['purpose', 'status', 'title']);
    });

    test('灵感的三态走另一张表：pending 是「未整理」，不是「未完成」（契约 §4.1）', () {
      final changes = describeFieldChanges(
        inspiration('i1'),
        inspiration(
          'i1',
          status: InspirationStatus.merged,
          mergedInto: 'p2',
          mergedAt: t1,
        ),
      );

      final status = changes.firstWhere((c) => c.key == 'status');
      expect(status.text, '状态：未整理 → 已合并');
    });

    test('diffStores 把同一份说明挂在红绿两行上：两边说的是同一件事', () {
      final diff = diffStores(
        base: store(<Project>[project('p1', title: '旧名')]),
        target: store(<Project>[project('p1', title: '新名')]),
      );

      final entries = diff.of(DocName.projects).entries;
      expect(entries.length, 2);
      expect(entries[0].side, DiffSide.previous);
      expect(entries[1].side, DiffSide.next);
      expect(entries[0].changes.single.text, '标题：旧名 → 新名');
      expect(entries[1].changes.single.text, '标题：旧名 → 新名');
    });

    test('只变了噪声键：红绿两行照旧，但底下不编假说明', () {
      final diff = diffStores(
        base: store(<Project>[project('p1')]),
        target: store(<Project>[project('p1', updatedAt: t1 + 60000)]),
      );

      final entries = diff.of(DocName.projects).entries;
      expect(entries.length, 2);
      expect(entries.every((e) => e.changes.isEmpty), isTrue);
      expect(entries.every((e) => e.hasChanges), isFalse);
    });

    test('新增/删除的行没有"改成了什么"：底下不写小字', () {
      final diff = diffStores(
        base: store(<Project>[project('p1'), project('p2')]),
        target: store(<Project>[project('p1'), project('p3')]),
      );

      final entries = diff.of(DocName.projects).entries;
      final removed = entries.firstWhere((e) => e.kind == DiffKind.removed);
      final added = entries.firstWhere((e) => e.kind == DiffKind.added);
      expect(removed.changes, isEmpty);
      expect(added.changes, isEmpty);
    });
  });
}
