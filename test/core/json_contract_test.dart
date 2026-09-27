import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';

/// 数据契约回归测试。
///
/// 判定标准只有一条：**读入 → 写出必须与样本逐字节一致**。
/// 单机形态下不再有"两端一致"的问题，但**自己的旧版本要能读新写的数据**，
/// 所以这条依然是最便宜的防退化手段。
void main() {
  const sampleDir = 'test/contract/sample';

  final collections = <DocName, String>{
    DocName.projects: '$sampleDir/projects.json',
    DocName.inspirations: '$sampleDir/inspirations.json',
    DocName.events: '$sampleDir/events.json',
    DocName.tasks: '$sampleDir/tasks.json',
  };

  group('集合样本逐字节回归', () {
    for (final entry in collections.entries) {
      test('${entry.key.fileName}：读入→写出与样本完全一致', () {
        final bytes = File(entry.value).readAsBytesSync();
        final text = utf8.decode(bytes);

        final issues = DecodeIssues();
        final document = Document.parse(entry.key, text, issues);

        expect(issues.errors, isEmpty, reason: '样本本身不应产生解析错误');
        expect(document.items, isNotEmpty);
        expect(utf8.encode(document.toCanonicalText()), equals(bytes));
      });
    }
  });

  group('单文件信封', () {
    test('store-file.json：读入→写出逐字节一致', () {
      final bytes = File('$sampleDir/store-file.json').readAsBytesSync();
      final text = utf8.decode(bytes);

      final issues = DecodeIssues();
      final store = StoreFile.parse(text, issues);

      expect(issues.errors, isEmpty);
      expect(store.savedAt, 1788652800000);
      for (final name in DocName.values) {
        expect(store.documentOf(name).items, isNotEmpty, reason: '${name.key} 应有样本记录');
      }
      expect(utf8.encode(store.toCanonicalText()), equals(bytes));
    });

    test('兼容 v1 四文档信封（从电脑端导出的旧数据可直接读入）', () {
      // v1 形态：{ "projects.json": {version, updated_at, last_tx_id, payload:{items}} }
      final v1 = <String, dynamic>{
        'projects.json': <String, dynamic>{
          'version': 42,
          'updated_at': 1788652800000,
          'last_tx_id': null,
          'payload': <String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{
                'id': 'p-1',
                'title': '旧数据',
                'purpose': '',
                'implementation': '',
                'date': null,
                'status': 'pending',
                'archived': false,
                'parent_project_id': null,
                'order': 1000,
                'completed_at': null,
                'created_at': 1788220800000,
                'updated_at': 1788220800000,
                'deleted': false,
              },
            ],
          },
        },
      };

      final issues = DecodeIssues();
      final store = StoreFile.parse(jsonEncode(v1), issues);

      expect(store.documentOf(DocName.projects).projectItems.single.title, '旧数据');
      expect(issues.warnings.any((w) => w.contains('v1')), isTrue, reason: '应提示走了兼容路径');
    });

    test('未来版本的文件被拒绝（而不是读成空数据）', () {
      final issues = DecodeIssues();
      final store = StoreFile.parse(
        '{"schemaVersion": 99, "savedAt": 1, "collections": {}}',
        issues,
      );
      expect(store.documentOf(DocName.projects).items, isEmpty);
      expect(issues.errors.any((e) => e.contains('高于')), isTrue);
    });
  });

  group('格式硬性要求', () {
    for (final entry in collections.entries) {
      test('${entry.key.fileName}：无 BOM / 仅 LF / 末尾单换行 / 无浮点', () {
        final bytes = File(entry.value).readAsBytesSync();
        final text = utf8.decode(bytes);

        final hasBom =
            bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;
        expect(hasBom, isFalse);
        expect(text.contains('\r'), isFalse);
        expect(text.endsWith('\n'), isTrue);
        expect(text.endsWith('\n\n'), isFalse);
        expect(RegExp(r'\d\.\d').hasMatch(text), isFalse, reason: '时间戳/序号必须是整数');
      });
    }
  });

  group('契约细节', () {
    test('可空字段必须写出 null，不省略 key', () {
      final text = File('$sampleDir/inspirations.json').readAsStringSync();
      expect(text.contains('"project_id": null'), isTrue);
      expect(text.contains('"merged_into": null'), isTrue);
      expect(text.contains('"merged_at": null'), isTrue);
    });

    test('灵感样本覆盖三种 status，且三态语义一致', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.inspirations,
        File('$sampleDir/inspirations.json').readAsStringSync(),
        issues,
      );
      final statuses = document.inspirationItems.map((i) => i.status).toSet();
      expect(statuses.contains(InspirationStatus.pending), isTrue);
      expect(statuses.contains(InspirationStatus.merged), isTrue);
      expect(statuses.contains(InspirationStatus.discarded), isTrue);
      expect(document.inspirationItems.where((i) => i.isMerged).every((i) => i.isConsistent), isTrue);
    });

    test('墓碑骨架只保留 3 个 key，且顺序固定', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.projects,
        File('$sampleDir/projects.json').readAsStringSync(),
        issues,
      );
      final tombstones = document.items.whereType<Tombstone>().toList();
      expect(tombstones, isNotEmpty);
      for (final tombstone in tombstones) {
        expect(tombstone.toJson().keys.toList(), <String>['id', 'deleted', 'purged_at']);
      }
    });

    test('项目样本覆盖"可省字段"的单独出现（T-10）', () {
      // `color` 与 `items` 都是"未设置即省略"的可省字段，位置追加在末尾。
      // 逐字节回归只对**样本里出现过的组合**有效，所以样本必须同时包含：
      // 只有 color 的、只有 items 的、两者都有、两者都无 —— 否则那几种写出形态没人守。
      final issues = DecodeIssues();
      final projects = Document.parse(
        DocName.projects,
        File('$sampleDir/projects.json').readAsStringSync(),
        issues,
      ).projectItems;

      expect(
        projects.where((p) => p.color != null && p.items.isEmpty),
        isNotEmpty,
        reason: '要有一条"只设了标识色、没有清单"的项目',
      );
      expect(
        projects.where((p) => p.color == null && p.items.isNotEmpty),
        isNotEmpty,
        reason: '要有一条"只有清单、没设标识色"的项目',
      );
      expect(
        projects.where((p) => p.color != null && p.items.isNotEmpty),
        isNotEmpty,
        reason: '要有一条两者都有的（字段顺序：color 在 items 之前）',
      );
      expect(
        projects.where((p) => p.color == null && p.items.isEmpty),
        isNotEmpty,
        reason: '要有一条两者都没有的（这两个键都不该写出来）',
      );
    });

    test('任务样本覆盖三类 task_type 与三层结构', () {      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.tasks,
        File('$sampleDir/tasks.json').readAsStringSync(),
        issues,
      );
      expect(document.taskItems.map((t) => t.taskType).toSet().length, 3);
      expect(document.taskItems.where((t) => t.isMainLine).length, greaterThanOrEqualTo(3));
      expect(document.taskItems.any((t) => !t.isMainLine && t.parentTaskId != null), isTrue);
    });

    test('未知字段透传：再序列化不丢字段', () {
      final issues = DecodeIssues();
      final document = Document.parse(
        DocName.projects,
        File('$sampleDir/projects.json').readAsStringSync(),
        issues,
      );
      final first = document.projectItems.first;
      final withExtra = Project.fromJson(
        <String, dynamic>{...first.toJson(), '未来字段': <String, dynamic>{'nested': true}},
        DecodeIssues(),
      );
      expect(withExtra.toJson()['未来字段'], isNotNull);
      expect(withExtra.extra.keys.toList(), <String>['未来字段']);
    });

    test('容错：枚举未知降级、类型错乱记录问题、JSON 损坏不抛异常', () {
      final issues = DecodeIssues();
      final broken = Document.parse(
        DocName.projects,
        '{"items": [{"id": "x", "title": 7, "status": "WHATEVER", "archived": false, '
            '"parent_project_id": null, "order": 1000, "completed_at": null, '
            '"created_at": "1700000000000", "updated_at": 1700000000000, '
            '"deleted": false, "date": "2026/01/01"}]}',
        issues,
      );
      expect(broken.items.length, 1);
      final project = broken.items.first as Project;
      expect(project.status.name, 'pending', reason: '未知枚举降级为 pending');
      expect(project.title, isEmpty, reason: '类型不符按默认值');
      expect(project.date, isNull, reason: '非法日期置空');
      expect(project.createdAt, 1700000000000, reason: '字符串数字被安全转换');
      expect(issues.isEmpty, isFalse);

      final garbage = Document.parse(DocName.tasks, 'not json at all', DecodeIssues());
      expect(garbage.items, isEmpty);
    });
  });
}
