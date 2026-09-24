import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/json/canonical.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';

/// 后加字段的兼容性（灵感整理第 5、10 条）：`Inspiration.tags` 与 `Project.color`。
///
/// 这两条的核心约束只有一句：**老数据必须照常读，而且读进来再写出去要逐字节不变**。
/// 所以新字段一律"未设置即省略"、位置追加在末尾。
void main() {
  Map<String, dynamic> inspirationJson({Object? tags, Map<String, dynamic> extra = const {}}) {
    return <String, dynamic>{
      'id': '11111111-2222-4333-8444-555555555555',
      'text': '一条灵感',
      'project_id': null,
      'status': 'pending',
      'merged_into': null,
      'merged_at': null,
      'created_at': 1788652800000,
      'updated_at': 1788652800000,
      'deleted': false,
      // 空值就整条不要这个键（`?` 作用在**值**上）
      'tags': ?tags,
      ...extra,
    };
  }

  Map<String, dynamic> projectJson({Object? color}) {
    return <String, dynamic>{
      'id': '22222222-3333-4444-8555-666666666666',
      'title': '一个项目',
      'purpose': '',
      'implementation': '',
      'date': null,
      'status': 'pending',
      'archived': false,
      'parent_project_id': null,
      'order': 1000,
      'completed_at': null,
      'created_at': 1788652800000,
      'updated_at': 1788652800000,
      'deleted': false,
      'color': ?color,
    };
  }

  group('灵感 tags', () {
    test('老数据没有 tags：读成空列表，且写出去**不带**这个字段', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.inspirations,
        Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[inspirationJson()],
        }),
        issues,
      );

      expect(issues.errors, isEmpty, reason: '缺字段不该报错');
      final inspiration = document.inspirationItems.single;
      expect(inspiration.tags, isEmpty);
      expect(document.toCanonicalText(), isNot(contains('"tags"')),
          reason: '空标签不写出，否则老文件会被无谓改写');
    });

    test('有 tags：按原顺序读入，写出去仍然逐字节一致', () {
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          inspirationJson(tags: <String>['工作', '生活']),
        ],
      });
      final issues = DecodeIssues();
      final document = Document.parse(DocName.inspirations, text, issues);

      expect(issues.errors, isEmpty);
      expect(document.inspirationItems.single.tags, <String>['工作', '生活']);
      expect(document.toCanonicalText(), text, reason: '读入→写出必须一模一样');
    });

    test('坏值容错：不是数组按空处理；非字符串项跳过；空串丢掉；重复项去重', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.inspirations,
        Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[
            inspirationJson(tags: '不是数组'),
            inspirationJson(
              tags: <Object?>['  工作  ', '', '工作', 42, null, '生活'],
            ),
          ],
        }),
        issues,
      );

      final items = document.inspirationItems.toList(growable: false);
      expect(items[0].tags, isEmpty);
      expect(
        items[1].tags,
        <String>['工作', '生活'],
        reason: 'trim、丢空串、去重、跳过非字符串项，但要保住有效的那几个',
      );
      // 坏值必须**记进 issues**，不能静默吞掉（契约 §8）
      expect(issues.errors.length, greaterThanOrEqualTo(3));
    });

    test('copyWith 能改标签，且不会丢掉其它字段', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.inspirations,
        Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[
            inspirationJson(tags: <String>['旧']),
          ],
        }),
        issues,
      );
      final inspiration = document.inspirationItems.single;
      final updated = inspiration.copyWith(tags: <String>['新'], updatedAt: 1);

      expect(updated.tags, <String>['新']);
      expect(updated.text, inspiration.text);
      expect(updated.status, inspiration.status);
      expect(updated.id, inspiration.id);
    });
  });

  group('项目 color', () {
    test('老数据没有 color：读成 null，写出去不带这个字段', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.projects,
        Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[projectJson()],
        }),
        issues,
      );

      expect(issues.errors, isEmpty);
      expect(document.projectItems.single.color, isNull);
      expect(document.toCanonicalText(), isNot(contains('"color"')));
    });

    test('有 color：读入后规范化成小写，写出去逐字节一致', () {
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[projectJson(color: '#2f6feb')],
      });
      final issues = DecodeIssues();
      final document = Document.parse(DocName.projects, text, issues);

      expect(issues.errors, isEmpty);
      expect(document.projectItems.single.color, '#2f6feb');
      expect(document.toCanonicalText(), text);
    });

    test('坏色值置 null 并记错（不是 #rrggbb 的一律不收）', () {
      for (final bad in <Object>['red', '#12345', '#1234567', '#GGGGGG', 123, '']) {
        final issues = DecodeIssues();
        final document = Document.parse(
          DocName.projects,
          Canonical.documentText(<String, dynamic>{
            'items': <Map<String, dynamic>>[projectJson(color: bad)],
          }),
          issues,
        );
        expect(document.projectItems.single.color, isNull, reason: '坏值：$bad');
        expect(issues.errors, isNotEmpty, reason: '坏值必须记进 issues：$bad');
      }
    });

    test('大小写与前后空格被规范化，不产生第二个写法', () {
      expect(Canonical.normalizeHexColor('  #2F6FEB '), '#2f6feb');
      expect(Canonical.normalizeHexColor('#2f6feb'), '#2f6feb');
      expect(Canonical.normalizeHexColor(null), isNull);
      expect(Canonical.normalizeHexColor('#2f6fe'), isNull);
    });

    test('copyWith(color: null) 能把标识色清掉（与"没传"区分开）', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.projects,
        Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[projectJson(color: '#2f6feb')],
        }),
        issues,
      );
      final project = document.projectItems.single;

      expect(project.copyWith().color, '#2f6feb', reason: '不传就保持原值');
      expect(project.copyWith(color: null).color, isNull, reason: '显式传 null 才是清空');
    });
  });

  group('未知字段仍然透传（不能被新字段挤掉）', () {
    test('tags / color 之外的未知字段照旧保留', () {
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          inspirationJson(tags: <String>['甲'], extra: <String, dynamic>{'future_field': '保留我'}),
        ],
      });
      final issues = DecodeIssues();
      final document = Document.parse(DocName.inspirations, text, issues);

      expect(document.inspirationItems.single.extra['future_field'], '保留我');
      expect(document.toCanonicalText(), text, reason: '透传 + 新字段都要能逐字节回去');
    });

    test('v1 四文档信封里的老数据也能读（不含新字段）', () {
      // v1 形态的键是**文件名**；`projects.json` 是判定"这是 v1 信封"的锚点，
      // 所以至少要带上它，只放一份 inspirations 不会被识别成 v1。
      final legacy = jsonEncode(<String, dynamic>{
        'projects.json': <String, dynamic>{
          'version': 1,
          'updated_at': 1788652800000,
          'last_tx_id': 'tx-1',
          'payload': <String, dynamic>{
            'items': <Map<String, dynamic>>[projectJson(color: '#2f6feb')],
          },
        },
        'inspirations.json': <String, dynamic>{
          'version': 1,
          'updated_at': 1788652800000,
          'last_tx_id': 'tx-1',
          'payload': <String, dynamic>{
            'items': <Map<String, dynamic>>[inspirationJson()],
          },
        },
      });
      final issues = DecodeIssues();
      final store = StoreFile.parse(legacy, issues);
      expect(issues.errors, isEmpty);
      expect(issues.warnings.any((w) => w.contains('v1')), isTrue, reason: '要走兼容路径');
      expect(store.documentOf(DocName.inspirations).inspirationItems.single.tags, isEmpty);
      expect(store.documentOf(DocName.projects).projectItems.single.color, '#2f6feb');
    });
  });
}
