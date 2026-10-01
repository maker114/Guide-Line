// 演示数据自检（本地工具，但**已入库**：`tool/` 是仓库路径，被 gitignore 的是 `.tools/`）。
//
// 走**和手机上完全一样的路径**：ExportCodec.decode（导入用的解码器）
// → AppStorage.save（导入就是整体替换+轮转备份）→ AppStorage.load
// → Workspace 查询各页面真正读的那些视图。
//
// 运行：dart run tool/demo_verify.dart

import 'dart:io';

import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/event.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/features/workspace.dart';
import 'package:guideline/ui/events/task_fold.dart';

const String _file = 'dist/guideline-演示数据.json';

int _failures = 0;

void check(bool ok, String what) {
  stdout.writeln('${ok ? '  ✓' : '  ✗'} $what');
  if (!ok) _failures += 1;
}

void main() {
  final file = File(_file);
  if (!file.existsSync()) {
    stderr.writeln('❌ 找不到 $_file —— 先跑 dart run tool/demo_seed.dart');
    exit(1);
  }

  // ---------------------------------------------------------- 1. 导入解码
  stdout.writeln('【1】导入解码（ExportCodec.decode，与手机导入同一入口）');
  final issues = DecodeIssues();
  final payload = ExportCodec.decode(file.readAsBytesSync(), issues);
  check(payload.readable, '可读：readable = true');
  check(issues.isEmpty, '零 warning / 零 error（实际 $issues）');
  if (!issues.isEmpty) {
    for (final w in issues.warnings) {
      stdout.writeln('      warn: $w');
    }
    for (final e in issues.errors) {
      stdout.writeln('      error: $e');
    }
  }
  stdout.writeln('      导入确认框会显示：${payload.countSummary}');

  // ---------------------------------------------------------- 2. 落盘 + 重载
  stdout.writeln('【2】落盘 + 重载（AppStorage，与 applyImport 同路径）');
  final dir = Directory.systemTemp.createTempSync('guideline_demo_');
  final storage = AppStorage(AppPaths(dir));
  // 手机上的导入是「存两次」的效果：先有一次既有数据，再被这份文件整体替换。
  storage.save(payload.store);
  storage.save(payload.store);
  final report = storage.load();
  check(!report.hasProblems, '重载无问题（quarantined=${report.quarantinedPaths.length}）');
  check(report.issues.isEmpty, '重载零 warning / 零 error（实际 ${report.issues}）');
  check(
    DocName.values.every((name) =>
        report.store.documentOf(name).toCanonicalText() ==
        payload.store.documentOf(name).toCanonicalText()),
    '四类记录存盘后与导入文件逐字节一致',
  );
  check(storage.listBackups().isNotEmpty, '替换前留下了一份滚动备份（可退回）');

  final ws = Workspace.fromLoad(storage, report);

  // ---------------------------------------------------------- 3. 引用完整性
  stdout.writeln('【3】引用完整性（契约 §4.3）');
  final allProjectIds = ws.allProjects.map((p) => p.id).toSet();
  final liveEventIds = ws.liveEvents.map((e) => e.id).toSet();

  check(
    ws.liveProjects.every((p) => p.parentId == null || allProjectIds.contains(p.parentId)),
    '每个 parent_project_id 都指向存在的项目',
  );
  check(
    ws.liveProjects.where((p) => p.status == NodeStatus.done).every((p) => p.completedAt != null) &&
        ws.liveProjects.where((p) => p.status != NodeStatus.done).every((p) => p.completedAt == null),
    '项目 status = done ⟺ completed_at != null',
  );
  check(
    ws.allEvents.every((e) => (e.status == NodeStatus.done) == (e.completedAt != null)),
    '事件 status = done ⟺ completed_at != null',
  );
  check(
    ws.liveTasks.every((t) => (t.taskType == TaskType.standard) == (t.parentId == null)),
    '任务 task_type = standard ⟺ parent_task_id 为空',
  );
  check(
    ws.liveTasks.every((t) => liveEventIds.contains(t.eventId)),
    '每个任务的 event_id 都存在',
  );
  check(
    ws.liveTasks.where((t) => t.parentId != null).every((t) {
      final parent = ws.findTask(t.parentId!);
      return parent != null && parent.eventId == t.eventId;
    }),
    '每个子任务的父任务存在且同事件',
  );
  check(
    ws.allInspirations.every((i) =>
        i.projectId == null || allProjectIds.contains(i.projectId) || i.deleted),
    '每个灵感的 project_id 都存在',
  );
  check(
    ws.allInspirations.every((i) => i.isConsistent),
    '灵感 merged ⟺ merged_into / merged_at 同时非空',
  );
  check(
    ws.liveProjects.every((p) => p.items.every((it) => it.text.trim().isNotEmpty)) &&
        ws.liveProjects.every((p) {
          final ids = p.items.map((it) => it.id).toList();
          return ids.length == ids.toSet().length;
        }),
    '清单条目非空且同项目内 id 不重复',
  );

  // ---------------------------------------------------------- 4. 灵感页
  stdout.writeln('【4】灵感页');
  final inbox = ws.inspirationInbox;
  check(inbox.length == 6 && inbox.every((i) => i.isPending), '未处理 ${inbox.length} 条，全是 pending');
  check(inbox.first.createdAt >= inbox.last.createdAt, '按创建时间倒序（最新在前）');
  check(inbox.any((i) => i.tags.isEmpty) && inbox.any((i) => i.tags.isNotEmpty), '既有带标签的也有不带的');
  check(inbox.any((i) => i.projectId == null) && inbox.any((i) => i.projectId != null), '既有未分配也有已分配');
  final hidden = ws.archiveZone.hiddenInspirations;
  check(hidden.length == 1, '归档区「被隐藏」${hidden.length} 条（灵感归属已归档项目）');

  // ---------------------------------------------------------- 5. 项目页
  stdout.writeln('【5】项目页');
  final roots = ws.liveProjects
      .where((p) => p.parentId == null && !p.archived)
      .toList()
    ..sort((a, b) => a.order.compareTo(b.order));
  for (final root in roots) {
    final kids = ws.projectTree.childrenOf(root.id);
    stdout.writeln('      · ${root.title}'
        '${root.color == null ? '（无标识色 → 灰色空心圆）' : '（${root.color} 实心圆）'}'
        '${root.date == null ? '' : ' 日期 ${root.date}'}'
        ' 清单 ${root.itemsDoneCount}/${root.items.length}'
        ' 子项目 ${kids.length}');
  }
  check(roots.length == 4, '可见根项目 ${roots.length} 个（归档/删除的不算）');
  check(roots.any((p) => p.color == null), '有一个根项目没有标识色（验证空心圆）');
  check(roots.any((p) => p.items.isNotEmpty), '有项目带实现清单');
  check(
    ws.liveProjects.any((p) {
      final mid = ws.liveProjects.where((c) => c.parentId == p.id);
      return mid.any((c) => ws.liveProjects.any((g) => g.parentId == c.id));
    }),
    '存在三层嵌套',
  );
  check(roots.any((p) => p.status == NodeStatus.done) && roots.any((p) => p.status == NodeStatus.ignored),
      '既有已完成也有已搁置的根项目');

  // ---------------------------------------------------------- 6. 事件页
  stdout.writeln('【6】事件页');
  final events = ws.liveEvents.where((e) => !e.archived).toList()
    ..sort((a, b) => a.order.compareTo(b.order));
  for (final event in events) {
    final main = ws.mainLineOf(event.id);
    final done = main.where((t) => t.status == NodeStatus.done).length;
    stdout.writeln('      · ${event.name} — 链路 ${main.length} 个节点（已完成 $done）');
  }
  final e1 = events.firstWhere((e) => e.name == '秋季版本发布');
  check(
    ws.mainLineOf(e1.id).every((t) => t.order > 0),
    '「秋季版本发布」是一条按 order 排的链（没有走向边了）',
  );
  // 列表页与详情页共用的"自动收起"规则：只留当前节点的上一个
  final line1 = ws.mainLineOf(e1.id);
  final folded = autoFoldedMainLineIds(line1);
  stdout.writeln('      自动收起 ${folded.length} 个：'
      '${line1.where((t) => folded.contains(t.id)).map((t) => t.title).join('、')}');
  check(folded.length == 2, '「秋季版本发布」收起 2 个（留当前节点的上一个当参照）');
  check(ws.checkEventCompletion(e1.id).canComplete == false, '「秋季版本发布」还不能完成（有未终态节点）');
  stdout.writeln('      子任务数量：'
      '${ws.allTasks.where((t) => t.taskType != TaskType.standard).length}');

  // ---------------------------------------------------------- 7. 更多页
  stdout.writeln('【7】更多页：到期 / 全部任务 / 归档区 / 搜索');
  String day(int offset) {
    final d = DateTime.now().add(Duration(days: offset));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  // `Workspace.tasksDueOnOrBefore` 已随代码演进删掉（这个工具在 .tools/ 里躺着时
  // 就悄悄烂了 —— 正是不入库的代价）。这里用现有 API 还原同一口径：
  // "到期日早于等于某天"的条数。`openTasks()` 已经排除已完成 / 已搁置 / 已归档，
  // 以及已搁置事件下的任务 —— 正是这份演示数据想验证的口径。
  int dueOnOrBefore(String limit) => ws
      .openTasks()
      .where((t) => t.dueAt != null && t.dueAt!.compareTo(limit) <= 0)
      .length;

  final today = dueOnOrBefore(day(0));
  final week = dueOnOrBefore(day(6));
  final overdue = dueOnOrBefore(day(-1));
  stdout.writeln('      到期：今天 $today 条 · 7 天内 $week 条 · 已逾期 $overdue 条');
  // 「健身计划（暂时搁置）」里那条每周三跑步被排除在外 —— 已搁置的事件不计入到期
  check(today == 4 && week == 9 && overdue == 2, '到期三档计数符合预期（4 / 9 / 2）');

  final liveTasks = ws.liveTasks.where((t) => !t.archived).toList();
  stdout.writeln('      全部任务：${liveTasks.length} 条（'
      '待处理 ${liveTasks.where((t) => t.status == NodeStatus.pending).length} · '
      '已完成 ${liveTasks.where((t) => t.status == NodeStatus.done).length} · '
      '已搁置 ${liveTasks.where((t) => t.status == NodeStatus.ignored).length}）');

  final zone = ws.archiveZone;
  stdout.writeln('      归档区：已归档 ${zone.archivedRoots.length} · 已丢弃 '
      '${zone.discardedInspirations.length} · 已合并 ${zone.mergedInspirations.length} · '
      '回收站 ${zone.trashRoots.length} · 被隐藏 ${zone.hiddenInspirations.length}');
  for (final entity in zone.archivedRoots) {
    stdout.writeln('        已归档 → ${entity.runtimeType}');
  }
  for (final entity in zone.trashRoots) {
    stdout.writeln('        回收站 → ${entity.runtimeType}');
  }
  check(
    zone.archivedRoots.length == 2 &&
        zone.discardedInspirations.length == 2 &&
        zone.mergedInspirations.length == 2 &&
        zone.trashRoots.length == 2 &&
        zone.hiddenInspirations.length == 1,
    '归档区五个分区齐全（已归档 / 已丢弃 / 已合并 / 回收站 / 被隐藏 = 2 / 2 / 2 / 2 / 1）',
  );
  check(
    zone.archivedRoots.whereType<Project>().length == 1 &&
        zone.archivedRoots.whereType<Event>().length == 1,
    '已归档里同时有项目与事件（只列归档根）',
  );
  check(
    zone.trashRoots.whereType<Project>().length == 1 &&
        zone.trashRoots.whereType<Event>().length == 1,
    '回收站里同时有项目与事件（只列级联根）',
  );

  for (final query in <String>['灵感', '打包', '搬家']) {
    final hits = ws.search(query);
    stdout.writeln('      搜索「$query」：${hits.length} 条命中'
        '（${hits.map((h) => h.doc.key).toSet().join(' / ')}）');
  }
  check(ws.search('灵感').length >= 3, '搜索「灵感」能跨项目 / 灵感命中');
  check(ws.search('打包').length >= 2, '搜索「打包」能命中项目 / 子项目 / 任务');
  check(ws.search('搬家').length >= 3, '搜索「搬家」能命中事件 / 灵感 / 任务');

  // ---------------------------------------------------------- 8. 墓碑
  stdout.writeln('【8】墓碑骨架（彻底删除后仍在文件里）');
  int tombs(DocName name) =>
      ws.documentOf(name).items.whereType<Tombstone>().length;
  stdout.writeln('      项目 ${tombs(DocName.projects)} · 灵感 ${tombs(DocName.inspirations)} · '
      '事件 ${tombs(DocName.events)} · 任务 ${tombs(DocName.tasks)}');
  check(
    tombs(DocName.projects) == 1 &&
        tombs(DocName.inspirations) == 1 &&
        tombs(DocName.events) == 1 &&
        tombs(DocName.tasks) == 1,
    '四类各有一条墓碑，且不出现在任何列表里',
  );

  dir.deleteSync(recursive: true);

  stdout.writeln('');
  if (_failures == 0) {
    stdout.writeln('✅ 全部自检通过 —— 可以导入。');
  } else {
    stderr.writeln('❌ 有 $_failures 项没通过。');
    exit(1);
  }
}
