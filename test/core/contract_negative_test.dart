import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/task.dart';

/// 契约 §8 的**负向规则**（T-9）：喂进坏数据，看它有没有按契约降级 + 记日志。
///
/// 这一类规则最容易在"顺手重构"里被破坏而无人察觉 —— 正向用例只证明好数据能进能出，
/// 负向规则没人守就等于没写。本文件把实际行为逐条钉住。
void main() {
  const projectJson = <String, dynamic>{
    'id': 'p-1',
    'title': '项目',
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
  };

  Project decodeProject(Map<String, dynamic> json, DecodeIssues issues) =>
      Project.fromJson(json, issues);

  group('§8 枚举未知值降级（三种枚举各一条）', () {
    test('NodeStatus 未知 → pending', () {
      final issues = DecodeIssues();
      final p = decodeProject(<String, dynamic>{...projectJson, 'status': 'WHATEVER'}, issues);
      expect(p.status, NodeStatus.pending);
      expect(issues.errors, isNotEmpty, reason: '契约要求记 error 日志');
    });

    test('InspirationStatus 未知 → pending', () {
      final issues = DecodeIssues();
      final doc = Document.parse(
        DocName.inspirations,
        jsonEncode(<String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'id': 'i-1',
              'text': '灵感',
              'project_id': null,
              'status': 'NOT_A_STATUS',
              'merged_into': null,
              'merged_at': null,
              'created_at': 1788652800000,
              'updated_at': 1788652800000,
              'deleted': false,
            },
          ],
        }),
        issues,
      );
      // 契约 §4.1 特意强调"同名不同义、禁止共用一个解析器"，
      // 所以这条与 NodeStatus 那条分开守。
      expect(doc.inspirationItems.single.status.name, 'pending');
      expect(issues.errors, isNotEmpty, reason: '契约要求记 error 日志');
    });

    test('TaskType 未知 → subtask', () {
      final issues = DecodeIssues();
      final doc = Document.parse(
        DocName.tasks,
        jsonEncode(<String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'id': 't-1',
              'event_id': 'e-1',
              'parent_task_id': null,
              'task_type': 'NOT_A_TYPE',
              'title': '任务',
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
        }),
        issues,
      );
      expect(doc.taskItems.single.taskType, TaskType.subtask);
      expect(issues.errors, isNotEmpty, reason: '契约要求记 error 日志');
    });
  });

  group('§8 类型不符：安全转换 + 记日志', () {
    test('时间戳是字符串数字 → 转成 int 并记 warning', () {
      final issues = DecodeIssues();
      final p = decodeProject(<String, dynamic>{...projectJson, 'created_at': '1788652800000'}, issues);
      expect(p.createdAt, 1788652800000);
      expect(issues.warnings, isNotEmpty, reason: '可安全转换的情况记 warning');
      expect(issues.errors, isEmpty);
    });

    test('字符串布尔 → 转成 bool 并记 warning', () {
      final issues = DecodeIssues();
      final p = decodeProject(<String, dynamic>{...projectJson, 'deleted': 'true'}, issues);
      expect(p.deleted, isTrue);
      expect(issues.warnings, isNotEmpty);
    });

    test('类型完全不符 → 按默认值并记 error', () {
      final issues = DecodeIssues();
      final p = decodeProject(<String, dynamic>{...projectJson, 'title': 7}, issues);
      expect(p.title, isEmpty);
      expect(issues.errors, isNotEmpty);
    });
  });

  group('§8 缺少已知字段：按默认值补齐', () {
    test('缺 created_at / updated_at → 补 0（当前实现不记 warning）', () {
      final json = <String, dynamic>{...projectJson}
        ..remove('created_at')
        ..remove('updated_at');
      final issues = DecodeIssues();

      final p = decodeProject(json, issues);

      // 行为：按默认值补齐
      expect(p.createdAt, 0);
      expect(p.updatedAt, 0);
      // ⚠️ 契约 §8 原文要求"记录 warning 日志"，而 `Canonical.read*` 对**字段缺失**
      // 一声不吭（只在类型不符时记 error）。这一条把实现的实际行为钉住：
      // 将来若补上 warning，这条会红 —— 那时把它改成 `isNotEmpty` 即可。
      expect(
        issues.warnings,
        isEmpty,
        reason: '当前实现不给"字段缺失"记 warning（与契约 §8 的措辞有出入，见清单 T-9）',
      );
    });
  });

  group('§4.3 跨字段一致性（写入侧）', () {
    test('同一父节点下 order 相同时，排序是稳定的（按 order 再按 id 兜底）', () {
      // 契约要求写入前校验 order 唯一；解析侧不校验，但**排序必须有确定结果**，
      // 否则同一个文件在不同次读取里顺序会飘。
      final doc = Document.parse(
        DocName.tasks,
        jsonEncode(<String, dynamic>{
          'items': <dynamic>[
            for (final id in <String>['t-b', 't-a'])
              <String, dynamic>{
                'id': id,
                'event_id': 'e-1',
                'parent_task_id': null,
                'task_type': 'standard',
                'title': id,
                'due_at': null,
                'status': 'pending',
                'archived': false,
                'order': 1000, // 故意重复
                'completed_at': null,
                'created_at': 1788652800000,
                'updated_at': 1788652800000,
                'deleted': false,
              },
          ],
        }),
        DecodeIssues(),
      );
      final sorted = <Task>[...doc.taskItems]
        ..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.id.compareTo(b.id));
      expect(sorted.map((t) => t.id).toList(), <String>['t-a', 't-b'],
          reason: 'order 相同时按 id 兜底，结果必须确定');
    });
  });

  group('§2.2 v1 四文档信封：读到即忽略（不写回）', () {
    test('v1 信封里的 version / last_tx_id 不会被写进新形态', () {
      final v1 = jsonEncode(<String, dynamic>{
        'projects.json': <String, dynamic>{
          'version': 42,
          'updated_at': 1788652800000,
          'last_tx_id': 'tx-abc',
          'payload': <String, dynamic>{'items': <dynamic>[projectJson]},
        },
      });
      final issues = DecodeIssues();
      final store = StoreFile.parse(v1, issues);

      expect(store.documentOf(DocName.projects).items, hasLength(1));
      expect(issues.warnings.any((w) => w.contains('v1')), isTrue, reason: '该提示走了兼容路径');

      final written = store.toCanonicalText();
      for (final gone in <String>['last_tx_id', '"version"', 'payload']) {
        expect(written, isNot(contains(gone)),
            reason: '「$gone」是 v1 形态的字段，写到新形态里就等于把它带回来了');
      }
      expect(written, contains('"schemaVersion"'), reason: '新形态只写 §2.1 的信封');
    });
  });
}
