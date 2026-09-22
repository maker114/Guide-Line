import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';

/// 数据契约回归测试（《数据契约》§6）。
///
/// 判定标准只有一条：**读入 → 写出必须与样本逐字节一致**。
void main() {
  const sampleDir = 'test/contract/sample';

  final samples = <DocName, String>{
    DocName.projects: '$sampleDir/projects.json',
    DocName.inspirations: '$sampleDir/inspirations.json',
    DocName.events: '$sampleDir/events.json',
    DocName.tasks: '$sampleDir/tasks.json',
  };

  group('样本逐字节回归', () {
    for (final entry in samples.entries) {
      test('${entry.key.fileName}：读入→写出与样本完全一致', () {
        final bytes = File(entry.value).readAsBytesSync();
        final text = utf8.decode(bytes);

        final issues = DecodeIssues();
        final doc = Document.parse(entry.key, text, issues);

        expect(issues.errors, isEmpty, reason: '样本本身不应产生解析错误');
        expect(doc.items, isNotEmpty);

        final encoded = utf8.encode(doc.toCanonicalText());
        expect(encoded, equals(bytes));
      });
    }
  });

  group('格式硬性要求（数据契约 §2）', () {
    for (final entry in samples.entries) {
      test('${entry.key.fileName}：无 BOM / 仅 LF / 末尾单换行 / 无浮点', () {
        final bytes = File(entry.value).readAsBytesSync();
        final text = utf8.decode(bytes);

        final hasBom = bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;
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

    test('灵感样本覆盖三种 status，且三态语义互斥', () {
      final issues = DecodeIssues();
      final doc = Document.parse(
        DocName.inspirations,
        File('$sampleDir/inspirations.json').readAsStringSync(),
        issues,
      );
      final statuses = doc.inspirationItems.map((i) => i.status).toSet();
      expect(statuses.contains(InspirationStatus.pending), isTrue);
      expect(statuses.contains(InspirationStatus.merged), isTrue);
      expect(statuses.contains(InspirationStatus.discarded), isTrue);
      expect(doc.inspirationItems.where((i) => i.isMerged).every((i) => i.isConsistent), isTrue);
    });

    test('墓碑骨架只保留 3 个 key，且顺序固定', () {
      final issues = DecodeIssues();
      final doc = Document.parse(
        DocName.projects,
        File('$sampleDir/projects.json').readAsStringSync(),
        issues,
      );
      final tombstones = doc.items.whereType<Tombstone>().toList();
      expect(tombstones, isNotEmpty);
      for (final tombstone in tombstones) {
        expect(tombstone.toJson().keys.toList(), <String>['id', 'deleted', 'purged_at']);
      }

      final text = File('$sampleDir/projects.json').readAsStringSync();
      expect(text.contains('"purged_at"'), isTrue);
    });

    test('任务样本覆盖三类 task_type 与三层嵌套', () {
      final issues = DecodeIssues();
      final doc = Document.parse(
        DocName.tasks,
        File('$sampleDir/tasks.json').readAsStringSync(),
        issues,
      );
      final types = doc.taskItems.map((t) => t.taskType).toSet();
      expect(types.length, 3);
      final mainLine = doc.taskItems.where((t) => t.isMainLine).toList();
      expect(mainLine.length, greaterThanOrEqualTo(3));
      expect(doc.taskItems.any((t) => !t.isMainLine && t.parentTaskId != null), isTrue);
    });

    test('未知字段透传：再序列化不丢字段', () {
      final issues = DecodeIssues();
      final doc = Document.parse(
        DocName.projects,
        File('$sampleDir/projects.json').readAsStringSync(),
        issues,
      );
      final first = doc.projectItems.first;
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
        '{"version": 1, "updated_at": null, "last_tx_id": null, '
            '"payload": {"items": [{"id": "x", "title": 7, "status": "WHATEVER", '
            '"archived": false, "parent_project_id": null, "order": 1000, '
            '"completed_at": null, "created_at": "1700000000000", "updated_at": 1700000000000, '
            '"deleted": false, "date": "2026/01/01"}]}}',
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
      expect(garbage.version, 0);
    });
  });
}
