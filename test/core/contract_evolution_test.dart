import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/json/canonical.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project_item.dart';

/// 后加字段的兼容性：`Inspiration.tags` 与 `Project.color`。
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

  Map<String, dynamic> eventJson({Object? color}) {
    return <String, dynamic>{
      'id': '33333333-4444-4555-8666-777777777777',
      'name': '一件事',
      'status': 'pending',
      'archived': false,
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
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[projectJson()],
      });
      final document = Document.parse(DocName.projects, text, issues);

      expect(issues.errors, isEmpty);
      expect(document.projectItems.single.color, isNull);
      expect(document.toCanonicalText(), text, reason: '没写出这个字段才会逐字节一致');
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

  group('事件 color（与项目同一套标识色系统）', () {
    test('老数据没有 color：读成 null，写出去不带这个字段', () {
      final issues = DecodeIssues();
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[eventJson()],
      });
      final document = Document.parse(DocName.events, text, issues);

      expect(issues.errors, isEmpty);
      expect(document.eventItems.single.color, isNull);
      expect(document.toCanonicalText(), text, reason: '没写出这个字段才会逐字节一致');
    });

    test('有 color：读入后规范化成小写，写出去逐字节一致', () {
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[eventJson(color: '#78d2ca')],
      });
      final issues = DecodeIssues();
      final document = Document.parse(DocName.events, text, issues);

      expect(issues.errors, isEmpty);
      expect(document.eventItems.single.color, '#78d2ca');
      expect(document.toCanonicalText(), text);

      // 大写 / 带空格也认得，但**规范化成小写**（否则同一个颜色会有两种写法）
      final upper = Document.parse(
        DocName.events,
        Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[eventJson(color: '  #78D2CA  ')],
        }),
        DecodeIssues(),
      );
      expect(upper.eventItems.single.color, '#78d2ca');
    });

    test('坏色值置 null 并记错', () {
      for (final bad in <Object>['蓝', '#12345', '#1234567', '#GGGGGG', 7, '']) {
        final issues = DecodeIssues();
        final document = Document.parse(
          DocName.events,
          Canonical.documentText(<String, dynamic>{
            'items': <Map<String, dynamic>>[eventJson(color: bad)],
          }),
          issues,
        );
        expect(document.eventItems.single.color, isNull, reason: '坏值：$bad');
        expect(issues.errors, isNotEmpty, reason: '坏值必须记进 issues：$bad');
      }
    });

    test('copyWith(color: null) 能把标识色清掉（与"没传"区分开）', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.events,
        Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[eventJson(color: '#78d2ca')],
        }),
        issues,
      );
      final event = document.eventItems.single;

      expect(event.copyWith().color, '#78d2ca', reason: '不传就保持原值');
      expect(event.copyWith(color: null).color, isNull, reason: '显式传 null 才是清空');
      expect(event.copyWith(name: '改了名').color, '#78d2ca', reason: '改别的字段不受影响');
    });
  });

  group('项目实现清单 items（《数据契约》§3.2.1）', () {
    Map<String, dynamic> item(String id, String text, bool done) =>
        <String, dynamic>{'id': id, 'text': text, 'done': done};

    Document parseProject(Map<String, dynamic> json, DecodeIssues issues) => Document.parse(
          DocName.projects,
          Canonical.documentText(<String, dynamic>{
            'items': <Map<String, dynamic>>[json],
          }),
          issues,
        );

    test('老项目没有 items：读成空清单，写出去**不带**这个字段', () {
      final issues = DecodeIssues();
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[projectJson()],
      });
      final document = Document.parse(DocName.projects, text, issues);

      expect(issues.errors, isEmpty);
      expect(document.projectItems.single.items, isEmpty);
      // 用"逐字节往返"来断言"没写出这个字段"：集合外层本来就有个 `items` 键，
      // 不能靠 `contains('"items"')` 判 —— 那命中的是外层那个。
      expect(document.toCanonicalText(), text);
    });

    test('有 items：顺序、勾选状态、id 都原样保留，且逐字节往返', () {
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            ...projectJson(),
            'items': <Map<String, dynamic>>[
              item('a-1', '第一条', true),
              item('a-2', '第二条', false),
              item('a-3', '第三条', true),
            ],
          },
        ],
      });
      final issues = DecodeIssues();
      final document = Document.parse(DocName.projects, text, issues);

      expect(issues.errors, isEmpty);
      final items = document.projectItems.single.items;
      expect(items.map((i) => i.id), <String>['a-1', 'a-2', 'a-3'], reason: '顺序就是数组下标');
      expect(items.map((i) => i.text), <String>['第一条', '第二条', '第三条']);
      expect(items.map((i) => i.done), <bool>[true, false, true]);
      expect(document.toCanonicalText(), text, reason: '读入→写出必须一模一样');
    });

    test('勾选状态不参与任何判定：清单全勾完也不影响项目 status', () {
      final issues = DecodeIssues();
      final document = parseProject(
        <String, dynamic>{
          ...projectJson(),
          'items': <Map<String, dynamic>>[
            item('a-1', '唯一的条目', true),
          ],
        },
        issues,
      );
      final project = document.projectItems.single;
      expect(project.itemsDoneCount, 1);
      expect(
        project.status,
        NodeStatus.pending,
        reason: '清单是纯文档，勾完也不该把项目变成已完成',
      );
    });

    test('坏条目只丢它自己，不连累整个项目', () {
      final issues = DecodeIssues();
      final document = parseProject(
        <String, dynamic>{
          ...projectJson(),
          'items': <Object?>[
            item('ok-1', '正常条目', false),
            '不是对象',
            <String, dynamic>{'id': 'no-text', 'done': false},
            <String, dynamic>{'text': '没有 id', 'done': false},
            <String, dynamic>{'id': 'blank', 'text': '   ', 'done': false},
            item('ok-1', '同 id 重复', false),
            item('ok-2', '  前后有空格  ', true),
          ],
        },
        issues,
      );

      final items = document.projectItems.single.items;
      expect(
        items.map((i) => i.id),
        <String>['ok-1', 'ok-2'],
        reason: '只留下两条合法条目',
      );
      expect(items.last.text, '前后有空格', reason: '读入时 trim');
      expect(items.last.done, isTrue);
      expect(issues.errors.length, greaterThanOrEqualTo(5), reason: '每条坏数据都要记 error');
    });

    test('items 不是数组时按空处理并记错', () {
      final issues = DecodeIssues();
      final document = parseProject(
        <String, dynamic>{...projectJson(), 'items': '不是数组'},
        issues,
      );
      expect(document.projectItems.single.items, isEmpty);
      expect(issues.errors, isNotEmpty);
    });

    test('条目里的未知字段也透传（未来加字段不会丢）', () {
      final text = Canonical.documentText(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            ...projectJson(),
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'a-1',
                'text': '带未来字段的条目',
                'done': false,
                'future_key': '保留我',
              },
            ],
          },
        ],
      });
      final issues = DecodeIssues();
      final document = Document.parse(DocName.projects, text, issues);

      expect(document.projectItems.single.items.single.extra['future_key'], '保留我');
      expect(document.toCanonicalText(), text);
    });

    test('copyWith(items:) 能换掉整个清单，其它字段不动', () {
      final issues = DecodeIssues();
      final document = parseProject(
        <String, dynamic>{
          ...projectJson(),
          'items': <Map<String, dynamic>>[item('a-1', '旧的', false)],
        },
        issues,
      );
      final project = document.projectItems.single;
      final updated = project.copyWith(
        items: <ProjectItem>[
          const ProjectItem(id: 'b-1', text: '新的', done: true),
        ],
      );

      expect(updated.items.single.id, 'b-1');
      expect(updated.title, project.title, reason: '没传的字段保持原值');
      expect(project.items.single.id, 'a-1', reason: '原对象不该被改动');
    });
  });

  group('未知字段仍然透传（不能被新字段挤掉）', () {    test('tags / color 之外的未知字段照旧保留', () {
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

  group('v3 破坏性变更：删掉 next_task_ids', () {
    String taskJson({Object? nextTaskIds}) => Canonical.documentText(<String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': '33333333-4444-4555-8666-777777777777',
              'event_id': '44444444-5555-4666-8777-888888888888',
              'parent_task_id': null,
              'next_task_ids': ?nextTaskIds,
              'task_type': 'standard',
              'title': '老文件里的一条任务',
              'due_at': null,
              'status': 'pending',
              'archived': false,
              'order': 1000,
              'completed_at': null,
              'created_at': 1788652800000,
              'updated_at': 1788652800000,
              'deleted': false,
            },
          ],
        });

    test('老文件里的走向边读得进来，但**写出时不再有**这个字段', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.tasks,
        taskJson(nextTaskIds: <String>['55555555-6666-4777-8888-999999999999']),
        issues,
      );

      expect(issues.errors, isEmpty, reason: '多出来的老字段不该让整条记录失败');
      expect(document.taskItems.single.title, '老文件里的一条任务');

      final written = document.toCanonicalText();
      expect(written.contains('next_task_ids'), isFalse, reason: 'v3 起这个字段彻底不写');
      expect(
        written.contains('"task_type": "standard"'),
        isTrue,
        reason: '除被删的字段之外，其余字段照旧',
      );
    });

    test('老文件里没有这个字段也一样（版本号只升不降）', () {
      final issues = DecodeIssues();
      final document = Document.parse(DocName.tasks, taskJson(), issues);
      expect(issues.errors, isEmpty);
      expect(document.toCanonicalText().contains('next_task_ids'), isFalse);
    });

    test('单文件信封把 schemaVersion 升到 3，v2 文件仍读得进来', () {
      expect(StoreFile.currentSchemaVersion, 3);

      final v2 = jsonEncode(<String, dynamic>{
        'schemaVersion': 2,
        'savedAt': 1788652800000,
        'collections': <String, dynamic>{
          'projects': <String, dynamic>{'items': <dynamic>[]},
          'inspirations': <String, dynamic>{'items': <dynamic>[]},
          'events': <String, dynamic>{'items': <dynamic>[]},
          'tasks': <String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': '66666666-7777-4888-8999-aaaaaaaaaaaa',
                'event_id': '44444444-5555-4666-8777-888888888888',
                'parent_task_id': null,
                'next_task_ids': <String>['77777777-8888-4999-8aaa-bbbbbbbbbbbb'],
                'task_type': 'standard',
                'title': 'v2 里的分叉点',
                'due_at': null,
                'status': 'pending',
                'archived': false,
                'order': 1000,
                'completed_at': null,
                'created_at': 1788652800000,
                'updated_at': 1788652800000,
                'deleted': false,
              },
            ],
          },
        },
      });

      final issues = DecodeIssues();
      final store = StoreFile.parse(v2, issues);
      expect(issues.errors, isEmpty);
      expect(store.documentOf(DocName.tasks).taskItems.single.title, 'v2 里的分叉点');
      // 再写出时按 v3 写：那个字段没了，版本号是 3
      final written = store.toCanonicalText();
      expect(written.contains('"schemaVersion": 3'), isTrue);
      expect(written.contains('next_task_ids'), isFalse);
    });
  });
}
