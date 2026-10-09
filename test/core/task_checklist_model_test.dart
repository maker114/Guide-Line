import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/task.dart';

/// 任务待办的**数据形态**那一层（《数据契约》§3.4.2）。
///
/// 三条要守住的性质：
///   1. **老文件照常读** —— 没有 `checklist` 字段的任务读进来就是空表，不记错；
///   2. **读进来再写出去逐字节一致** —— 字段位置固定追加在末尾、空清单也照写 `[]`；
///   3. **坏条目只丢它自己** —— 与项目清单共用同一套解析（`ProjectItem`），
///      一条脏数据不该让整条任务读不出来。
void main() {
  /// 一条任务的完整 JSON，`checklist` 由用例决定给不给。
  String taskJson({String? checklist}) => '''
{
  "id": "t1",
  "event_id": "e1",
  "parent_task_id": null,
  "task_type": "standard",
  "title": "写解析层",
  "due_at": null,
  "status": "pending",
  "archived": false,
  "order": 1000,
  "completed_at": null,
  "created_at": 1788220800000,
  "updated_at": 1788307200000,
  "deleted": false${checklist == null ? '' : ',\n  "checklist": $checklist'}
}''';

  Task parse(String text, DecodeIssues issues) =>
      Task.fromJson(json.decode(text) as Map<String, dynamic>, issues);

  test('老文件没有 checklist：读成空表，且不记错（该字段定稿时已存在）', () {
    final issues = DecodeIssues();
    final task = parse(taskJson(), issues);

    expect(task.checklist, isEmpty);
    expect(issues.warnings, isEmpty);
    expect(issues.errors, isEmpty);
  });

  test('有 checklist：顺序、勾选状态、id 原样保留', () {
    final task = parse(
      taskJson(
        checklist: '[{"id": "c1", "text": "先写契约", "done": true},'
            ' {"id": "c2", "text": "再写实现", "done": false}]',
      ),
      DecodeIssues(),
    );

    expect(task.checklist.map((i) => i.id), <String>['c1', 'c2']);
    expect(task.checklist.map((i) => i.text), <String>['先写契约', '再写实现']);
    expect(task.checklist.map((i) => i.done), <bool>[true, false]);
  });

  test('读入 → 写出**逐字节一致**（含空清单与非空清单两种形态）', () {
    final withItems = '''
{
  "id": "t1",
  "event_id": "e1",
  "parent_task_id": null,
  "task_type": "standard",
  "title": "写解析层",
  "due_at": null,
  "status": "pending",
  "archived": false,
  "order": 1000,
  "completed_at": null,
  "created_at": 1788220800000,
  "updated_at": 1788307200000,
  "deleted": false,
  "checklist": [
    {
      "id": "c1",
      "text": "先写契约",
      "done": true
    },
    {
      "id": "c2",
      "text": "再写实现",
      "done": false
    }
  ]
}''';

    for (final text in <String>[taskJson(checklist: '[]'), withItems]) {
      final written = parse(text, DecodeIssues()).toJson();
      // 与逐字节回归同一条判据：写出必须与原文一模一样（含字段顺序与缩进）
      expect(
        const JsonEncoder.withIndent('  ').convert(written),
        text,
        reason: 'checklist 固定追加在 `deleted` 之后，空表也要照写 `[]`',
      );
    }
  });

  test('坏条目只丢它自己：不是对象 / 缺 id / 文本为空 / id 重复', () {
    final issues = DecodeIssues();
    final task = parse(
      taskJson(
        checklist: '["不是对象",'
            ' {"text": "缺 id", "done": false},'
            ' {"id": "c2", "text": "   ", "done": false},'
            ' {"id": "c3", "text": "好的", "done": false},'
            ' {"id": "c3", "text": "id 重复", "done": true}]',
      ),
      issues,
    );

    expect(task.checklist.map((i) => i.text), <String>['好的'],
        reason: '坏条目只丢它自己，好的那条照读');
    expect(issues.errors.length, 4);
  });

  test('checklist 不是数组：按空表处理并记一条错，不抛异常', () {
    final issues = DecodeIssues();
    final task = parse(taskJson(checklist: '"我不是数组"'), issues);

    expect(task.checklist, isEmpty);
    expect(issues.errors.single, contains('task.checklist'));
  });

  test('条目里的未知键原样透传（契约 §8：读进来再写出去不许抹掉）', () {
    final task = parse(
      taskJson(checklist: '[{"id": "c1", "text": "一条", "done": false, "备注": "留着"}]'),
      DecodeIssues(),
    );
    expect(task.checklist.single.extra, <String, dynamic>{'备注': '留着'});
    expect(task.checklist.single.toJson()['备注'], '留着');
  });

  test('copyWith 能**清空**清单（空数组是合法值，不能被当成"没传"）', () {
    final task = parse(
      taskJson(checklist: '[{"id": "c1", "text": "一条", "done": false}]'),
      DecodeIssues(),
    );
    expect(task.copyWith(checklist: const []).checklist, isEmpty);
    expect(task.copyWith().checklist.length, 1, reason: '不传时保持原样');
  });
}
