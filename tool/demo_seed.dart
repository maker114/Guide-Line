// 演示数据生成器（本地工具，但**已入库**：`tool/` 是仓库路径，被 gitignore 的是 `.tools/`）。
//
// 用途：造一份**覆盖全部功能**的导入文件 —— 项目/灵感/事件/任务四类记录都用真模型
// （`lib/core/models/*`）构造，再经 `Canonical.documentText` 落盘，所以字段顺序、
// 可空形态、数组写法一定与《数据契约》一致。
//
// 生成后自己再解析一遍：`StoreFile.parse` 必须零 warning / 零 error，
// 且「读入 → 写出」逐字节一致 —— 契约样本测试用的是同一套判据。
//
// 运行：dart run tool/demo_seed.dart

import 'dart:convert';
import 'dart:io';

import 'package:guideline/core/json/canonical.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/event.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/models/project_item.dart';
import 'package:guideline/core/models/task.dart';

// ------------------------------------------------------------------ 小工具

const String _pProject = '11111111';
const String _pEvent = '22222222';
const String _pTask = '33333333';
const String _pInspiring = '44444444';
const String _pItem = '55555555';

final Map<String, int> _counters = <String, int>{};

/// 确定性 UUID：8-4-4-4-12，版本位 4、变体位 8 —— 形态合法且肉眼可读，
/// 演示数据里"谁引用了谁"能直接对得上。
String _id(String prefix) {
  final n = (_counters[prefix] ?? 0) + 1;
  _counters[prefix] = n;
  return '$prefix-0000-4000-8000-${n.toString().padLeft(12, '0')}';
}

final DateTime _now = DateTime.now();

int _ago({int minutes = 0, int hours = 0, int days = 0}) => _now
    .subtract(Duration(minutes: minutes, hours: hours, days: days))
    .millisecondsSinceEpoch;

/// 相对今天偏移 [offset] 天的 `YYYY-MM-DD`（到期日全部相对生成日，方便演示紧迫度）。
String _day(int offset) {
  final d = DateTime(_now.year, _now.month, _now.day).add(Duration(days: offset));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

ProjectItem _item(String text, {bool done = false}) =>
    ProjectItem(id: _id(_pItem), text: text, done: done);

Project _project({
  required String id,
  required String title,
  String purpose = '',
  String implementation = '',
  String? date,
  NodeStatus status = NodeStatus.pending,
  bool archived = false,
  String? parent,
  int order = 1000,
  int? completedAt,
  bool deleted = false,
  String? color,
  List<ProjectItem> items = const <ProjectItem>[],
  required int createdAt,
  int? updatedAt,
}) => Project(
  id: id,
  title: title,
  purpose: purpose,
  implementation: implementation,
  date: date,
  status: status,
  archived: archived,
  parentProjectId: parent,
  order: order,
  completedAt: completedAt,
  createdAt: createdAt,
  updatedAt: updatedAt ?? createdAt,
  deleted: deleted,
  color: color,
  items: items,
);

Inspiration _inspiration({
  required String text,
  String? project,
  InspirationStatus status = InspirationStatus.pending,
  String? mergedInto,
  int? mergedAt,
  List<String> tags = const <String>[],
  bool deleted = false,
  required int createdAt,
  int? updatedAt,
}) => Inspiration(
  id: _id(_pInspiring),
  text: text,
  projectId: project,
  status: status,
  mergedInto: mergedInto,
  mergedAt: mergedAt,
  createdAt: createdAt,
  updatedAt: updatedAt ?? createdAt,
  deleted: deleted,
  tags: tags,
);

Event _event({
  required String name,
  NodeStatus status = NodeStatus.pending,
  bool archived = false,
  bool deleted = false,
  int order = 1000,
  int? completedAt,
  required int createdAt,
  int? updatedAt,
}) => Event(
  id: _id(_pEvent),
  name: name,
  status: status,
  archived: archived,
  order: order,
  completedAt: completedAt,
  createdAt: createdAt,
  updatedAt: updatedAt ?? createdAt,
  deleted: deleted,
);

Task _task({
  required String eventId,
  required String title,
  String? parent,
  TaskType type = TaskType.standard,
  String? dueAt,
  NodeStatus status = NodeStatus.pending,
  bool archived = false,
  bool deleted = false,
  int order = 1000,
  int? completedAt,
  required int createdAt,
  int? updatedAt,
}) => Task(
  id: _id(_pTask),
  eventId: eventId,
  parentTaskId: parent,
  taskType: type,
  title: title,
  dueAt: dueAt,
  status: status,
  archived: archived,
  order: order,
  completedAt: completedAt,
  createdAt: createdAt,
  updatedAt: updatedAt ?? createdAt,
  deleted: deleted,
);

void main() {
  // ---------------------------------------------------------------- 项目
  //
  // 覆盖：标识色（实心圆）/ 无标识色（灰色空心圆）/ 三层嵌套 / 清单进度 /
  //      已完成 / 已搁置 / 已归档 / 已删除 / 墓碑骨架 / 目的与正文长短。

  final p1 = _project(
    id: _id(_pProject),
    title: 'Guide Line 用起来',
    purpose: '把散落在备忘录、聊天记录、脑子里的想法收进一个自己能掌控的地方，别再丢。',
    implementation:
        '三件事先立成规矩：灵感随手记、项目有颜色、实现能打勾。\n\n'
        '每天睡前 5 分钟过一遍灵感箱：能归到项目就归，归不了就先留着。\n'
        '周末给这一周动过的项目更新一次日期与进度。',
    date: _day(3),
    color: '#87c57e',
    items: <ProjectItem>[
      _item('把手机备忘录里的旧笔记导进来', done: true),
      _item('每天睡前过一遍灵感箱'),
      _item('给每个项目设一个标识色'),
      _item('把「实现」写成能打勾的清单'),
    ],
    createdAt: _ago(days: 12),
    updatedAt: _ago(minutes: 30),
  );

  final p2 = _project(
    id: _id(_pProject),
    title: '先梳理手上正在做的事',
    purpose: '先看清手上有什么，再谈安排 —— 不梳理就排期，等于给混乱加个日历。',
    implementation: '把在做的、想做的、别人托付的分成三堆，两周内只动第一堆。',
    date: _day(7),
    parent: p1.id,
    color: '#a9bfd5',
    items: <ProjectItem>[
      _item('列出所有在做的事', done: true),
      _item('标出真正有截止日的', done: true),
      _item('给每件事写一句「不做会怎样」'),
    ],
    createdAt: _ago(days: 10),
    updatedAt: _ago(hours: 3),
  );

  final p3 = _project(
    id: _id(_pProject),
    title: '把灵感全都记下来',
    purpose: '这一层的意义是证明项目能嵌三层。',
    status: NodeStatus.done,
    completedAt: _ago(days: 1),
    parent: p2.id,
    date: _day(-2),
    items: <ProjectItem>[_item('装上应用，先记 10 条', done: true)],
    createdAt: _ago(days: 9),
    updatedAt: _ago(days: 1),
  );

  final p4 = _project(
    id: _id(_pProject),
    title: '读完《深度工作》',
    purpose: '一年读 12 本，读得进去比读得快重要。这本放了两个月，先搁置。',
    implementation: '每天 30 分钟纸质阅读，手机放另一个房间；读完写 200 字笔记。',
    date: _day(-1),
    status: NodeStatus.ignored,
    order: 2000,
    color: '#a85780',
    items: <ProjectItem>[
      _item('读到第 3 章', done: true),
      _item('读完全书'),
      _item('写一篇读书笔记'),
    ],
    createdAt: _ago(days: 40),
    updatedAt: _ago(days: 8),
  );

  final p5 = _project(
    id: _id(_pProject),
    title: '搬家准备（已归档）',
    purpose: '十一前搬完，重点是书和电子设备。',
    implementation: '按房间推进，每箱书编号登记。',
    date: _day(30),
    order: 3000,
    archived: true,
    color: '#78d2ca',
    items: <ProjectItem>[
      _item('约搬家公司上门看', done: true),
      _item('买纸箱与气泡膜'),
    ],
    createdAt: _ago(days: 20),
    updatedAt: _ago(days: 4),
  );

  final p6 = _project(
    id: _id(_pProject),
    title: '打包旧书',
    purpose: '书是这次搬家最麻烦的部分。',
    order: 1000,
    parent: p5.id,
    archived: true,
    color: '#b87f56',
    createdAt: _ago(days: 18),
    updatedAt: _ago(days: 4),
  );

  final p7 = _project(
    id: _id(_pProject),
    title: '旧版重构方案（已删除）',
    purpose: '这条在回收站里，恢复后会连同子项目一起回来。',
    order: 4000,
    deleted: true,
    color: '#8280ae',
    items: <ProjectItem>[_item('拆分模块')],
    createdAt: _ago(days: 60),
    updatedAt: _ago(days: 15),
  );

  final p8 = _project(
    id: _id(_pProject),
    title: '重构 · 数据层（随父删除）',
    order: 1000,
    parent: p7.id,
    deleted: true,
    createdAt: _ago(days: 55),
    updatedAt: _ago(days: 15),
  );

  final p9 = _project(
    id: _id(_pProject),
    title: '健康作息',
    purpose: '完成的项目在列表里是勾掉的样子，颜色还在。',
    implementation: '十一点半上床，早上七点起。',
    date: _day(-10),
    status: NodeStatus.done,
    completedAt: _ago(days: 9),
    order: 5000,
    color: '#87c7ad',
    items: <ProjectItem>[
      _item('连续 21 天 23:30 前上床', done: true),
      _item('把闹钟换成床头钟', done: true),
    ],
    createdAt: _ago(days: 45),
    updatedAt: _ago(days: 9),
  );

  final p10 = _project(
    id: _id(_pProject),
    title: '随手记（还没想清楚）',
    order: 6000,
    createdAt: _ago(days: 2),
    updatedAt: _ago(days: 2),
  );

  // ---------------------------------------------------------------- 灵感
  //
  // 覆盖：未分配 / 已分配 / 带标签 / 无标签 / 已合并 / 已丢弃 / 归属已归档项目
  //      （归档区「被隐藏」）/ 墓碑骨架 / emoji / 排序。

  final inspirations = <Inspiration>[
    _inspiration(
      text: '灵感箱顶部要能直接记，不点任何按钮。',
      tags: <String>['产品', '体验'],
      createdAt: _ago(minutes: 5),
    ),
    _inspiration(
      text: '每天只做三件事，做完就算赢 🎯 剩下的时间留给意外。',
      tags: <String>['原则'],
      createdAt: _ago(hours: 1),
    ),
    _inspiration(
      text: '项目列表给一个「只看没做完的」开关。',
      tags: <String>['体验'],
      createdAt: _ago(hours: 6),
    ),
    _inspiration(
      text: '每个项目一个标识色，翻列表时一眼认出归属。',
      project: p1.id,
      tags: <String>['待定'],
      createdAt: _ago(hours: 20),
    ),
    _inspiration(
      text: '搬家前把每箱书编号登记，到了新家好找。',
      project: p5.id,
      createdAt: _ago(days: 1, hours: 2),
    ),
    _inspiration(
      text: '把「实现」拆成一条条能打勾的清单，进度一眼看得见。',
      project: p2.id,
      tags: <String>['清单'],
      createdAt: _ago(days: 2),
    ),
    _inspiration(
      text: '灵感合并进项目时，正文要保留原文。',
      status: InspirationStatus.merged,
      mergedInto: p1.id,
      mergedAt: _ago(days: 1),
      createdAt: _ago(days: 6),
    ),
    _inspiration(
      text: '睡前把手机放到客厅充电。',
      status: InspirationStatus.merged,
      mergedInto: p9.id,
      mergedAt: _ago(days: 2),
      createdAt: _ago(days: 8),
    ),
    _inspiration(
      text: '做一个桌面小组件，把今天的三件事贴在桌面上。',
      status: InspirationStatus.discarded,
      createdAt: _ago(days: 9),
    ),
    _inspiration(
      text: '接入云端同步，多台设备共用一份数据。',
      status: InspirationStatus.discarded,
      createdAt: _ago(days: 10),
    ),
  ];

  // ---------------------------------------------------------------- 事件与任务

  // --- 事件 1：一条链 + 子任务 + 已完成自动折叠
  final e1 = _event(
    name: '秋季版本发布',
    createdAt: _ago(days: 25),
    updatedAt: _ago(hours: 2),
  );

  final t1 = _task(
    eventId: e1.id,
    title: '需求盘点',
    dueAt: _day(-6),
    status: NodeStatus.done,
    completedAt: _ago(days: 5),
    order: 1000,
    createdAt: _ago(days: 25),
  );
  final t1a = _task(
    eventId: e1.id,
    title: '找 5 位用户聊 20 分钟',
    parent: t1.id,
    type: TaskType.subtask,
    status: NodeStatus.done,
    completedAt: _ago(days: 7),
    order: 1000,
    createdAt: _ago(days: 24),
  );
  final t1b = _task(
    eventId: e1.id,
    title: '整理竞品清单',
    parent: t1.id,
    type: TaskType.subtask,
    status: NodeStatus.done,
    completedAt: _ago(days: 6),
    order: 2000,
    createdAt: _ago(days: 24),
  );

  final t2 = _task(
    eventId: e1.id,
    title: '写方案',
    dueAt: _day(-1),
    status: NodeStatus.done,
    completedAt: _ago(days: 1),
    order: 2000,
    createdAt: _ago(days: 20),
  );
  // 这个节点框内的两条下级：**并列任务已废除**（见《数据契约》§4.1），
  // 所以这里按子任务写 —— 演示数据只放"现在造得出来"的东西
  final t2p1 = _task(
    eventId: e1.id,
    title: '先把要做的东西列成清单',
    parent: t2.id,
    type: TaskType.subtask,
    status: NodeStatus.done,
    completedAt: _ago(days: 2),
    order: 1000,
    createdAt: _ago(days: 19),
  );
  final t2p2 = _task(
    eventId: e1.id,
    title: '再把主题与配色定下来',
    parent: t2.id,
    type: TaskType.subtask,
    status: NodeStatus.done,
    completedAt: _ago(days: 2),
    order: 2000,
    createdAt: _ago(days: 19),
  );

  // 这条链上前几个节点都做完了 —— 正好演示"已完成自动收起"：
  // 当前节点（开发排期）的上一个（设计定稿）留着当参照，更早的两个收起
  final t3 = _task(
    eventId: e1.id,
    title: '设计定稿',
    dueAt: _day(-1),
    status: NodeStatus.done,
    completedAt: _ago(days: 1),
    order: 3000,
    createdAt: _ago(days: 15),
  );
  final t3s = _task(
    eventId: e1.id,
    title: '校对文案错别字',
    parent: t3.id,
    type: TaskType.subtask,
    dueAt: _day(3),
    order: 1000,
    createdAt: _ago(days: 14),
  );

  final t4 = _task(
    eventId: e1.id,
    title: '开发排期（正在做）',
    dueAt: _day(1),
    order: 4000,
    createdAt: _ago(days: 15),
  );
  final t4s = _task(
    eventId: e1.id,
    title: '把方案拆成可估点的任务',
    parent: t4.id,
    type: TaskType.subtask,
    status: NodeStatus.done,
    completedAt: _ago(days: 4),
    order: 1000,
    createdAt: _ago(days: 14),
  );

  final t5 = _task(
    eventId: e1.id,
    title: '发布上线',
    dueAt: _day(0),
    order: 5000,
    createdAt: _ago(days: 13),
  );

  // --- 事件 2：到期各档（老数据形态：没有显式边，按 order 成链）
  final e2 = _event(
    name: '搬家',
    order: 2000,
    createdAt: _ago(days: 16),
    updatedAt: _ago(hours: 8),
  );
  final e2a = _task(
    eventId: e2.id,
    title: '联系搬家公司上门看（已逾期）',
    dueAt: _day(-3),
    order: 1000,
    createdAt: _ago(days: 16),
  );
  final e2b = _task(
    eventId: e2.id,
    title: '确认新家水电燃气（今天）',
    dueAt: _day(0),
    order: 2000,
    createdAt: _ago(days: 15),
  );
  final e2c = _task(
    eventId: e2.id,
    title: '打包厨房（3 天内）',
    dueAt: _day(2),
    order: 3000,
    createdAt: _ago(days: 14),
  );
  final e2c1 = _task(
    eventId: e2.id,
    title: '买纸箱与气泡膜',
    parent: e2c.id,
    type: TaskType.subtask,
    dueAt: _day(-1),
    order: 1000,
    createdAt: _ago(days: 14),
  );
  final e2d = _task(
    eventId: e2.id,
    title: '打包卧室与衣柜（5 天内）',
    dueAt: _day(4),
    order: 4000,
    createdAt: _ago(days: 13),
  );
  final e2e = _task(
    eventId: e2.id,
    title: '退掉宽带（7 天内）',
    dueAt: _day(6),
    order: 5000,
    createdAt: _ago(days: 12),
  );
  final e2f = _task(
    eventId: e2.id,
    title: '注销旧地址的快递代收（7 天后）',
    dueAt: _day(20),
    order: 6000,
    createdAt: _ago(days: 11),
  );
  final e2g = _task(
    eventId: e2.id,
    title: '给旧房墙上补漆（没有到期日）',
    order: 7000,
    createdAt: _ago(days: 10),
  );
  final e2h = _task(
    eventId: e2.id,
    title: '扔掉旧沙发（已完成）',
    dueAt: _day(-5),
    status: NodeStatus.done,
    completedAt: _ago(days: 4),
    order: 8000,
    createdAt: _ago(days: 10),
  );
  final e2i = _task(
    eventId: e2.id,
    title: '处理按摩椅（已搁置）',
    status: NodeStatus.ignored,
    order: 9000,
    createdAt: _ago(days: 10),
  );

  // --- 事件 3：已完成事件
  final e3 = _event(
    name: '准备资格考试',
    status: NodeStatus.done,
    completedAt: _ago(days: 3),
    order: 3000,
    createdAt: _ago(days: 90),
    updatedAt: _ago(days: 3),
  );
  final e3a = _task(
    eventId: e3.id,
    title: '报名缴费',
    dueAt: _day(-30),
    status: NodeStatus.done,
    completedAt: _ago(days: 31),
    order: 1000,
    createdAt: _ago(days: 90),
  );
  final e3b = _task(
    eventId: e3.id,
    title: '刷完近五年真题',
    dueAt: _day(-10),
    status: NodeStatus.done,
    completedAt: _ago(days: 11),
    order: 2000,
    createdAt: _ago(days: 60),
  );
  final e3c = _task(
    eventId: e3.id,
    title: '上考场',
    dueAt: _day(-3),
    status: NodeStatus.done,
    completedAt: _ago(days: 3),
    order: 3000,
    createdAt: _ago(days: 60),
  );

  // --- 事件 4：已搁置事件（仍有一条待办会出现在「到期」里）
  final e4 = _event(
    name: '健身计划（暂时搁置）',
    status: NodeStatus.ignored,
    order: 4000,
    createdAt: _ago(days: 35),
    updatedAt: _ago(days: 12),
  );
  final e4a = _task(
    eventId: e4.id,
    title: '办一张年卡',
    status: NodeStatus.ignored,
    order: 1000,
    createdAt: _ago(days: 35),
  );
  final e4b = _task(
    eventId: e4.id,
    title: '每周三跑步 5 公里',
    dueAt: _day(5),
    order: 2000,
    createdAt: _ago(days: 35),
  );

  // --- 事件 5：已归档（任务随事件级联归档）
  final e5 = _event(
    name: '旧版需求整理（已归档）',
    archived: true,
    order: 5000,
    createdAt: _ago(days: 70),
    updatedAt: _ago(days: 40),
  );
  final e5a = _task(
    eventId: e5.id,
    title: '把聊天记录里的需求抄出来',
    status: NodeStatus.done,
    completedAt: _ago(days: 62),
    archived: true,
    order: 1000,
    createdAt: _ago(days: 70),
  );
  final e5b = _task(
    eventId: e5.id,
    title: '归类并标优先级',
    archived: true,
    order: 2000,
    createdAt: _ago(days: 70),
  );

  // --- 事件 6：已删除（回收站；任务是级联子记录）
  final e6 = _event(
    name: '上一次搬家的复盘（已删除）',
    deleted: true,
    order: 6000,
    createdAt: _ago(days: 120),
    updatedAt: _ago(days: 50),
  );
  final e6a = _task(
    eventId: e6.id,
    title: '列出当时踩的坑',
    deleted: true,
    order: 1000,
    createdAt: _ago(days: 120),
  );
  final e6b = _task(
    eventId: e6.id,
    title: '写一篇复盘',
    deleted: true,
    order: 2000,
    createdAt: _ago(days: 120),
  );

    final tasks = <Task>[
    t1,
    t1a,
    t1b,
    t2,
    t2p1,
    t2p2,
    t3,
    t3s,
    t4,
    t4s,
    t5,
    e2a,
    e2b,
    e2c,
    e2c1,
    e2d,
    e2e,
    e2f,
    e2g,
    e2h,
    e2i,
    e3a,
    e3b,
    e3c,
    e4a,
    e4b,
    e5a,
    e5b,
    e6a,
    e6b,
  ];

  // ---------------------------------------------------------------- 墓碑骨架
  // 「彻底删除」后的残留形态：只剩 3 个 key，仍留在 items 里（契约 §3.5）。

  final projects = <Entity>[
    p1, p2, p3, p4, p5, p6, p7, p8, p9, p10,
    Tombstone(id: _id(_pProject), purgedAt: _ago(days: 100)),
  ];
  final events = <Entity>[
    e1, e2, e3, e4, e5, e6,
    Tombstone(id: _id(_pEvent), purgedAt: _ago(days: 100)),
  ];
  final allTasks = <Entity>[
    ...tasks,
    Tombstone(id: _id(_pTask), purgedAt: _ago(days: 100)),
  ];
  final allInspirations = <Entity>[
    ...inspirations,
    Tombstone(id: _id(_pInspiring), purgedAt: _ago(days: 100)),
  ];

  // ---------------------------------------------------------------- 落盘

  final store = StoreFile(
    documents: <DocName, Document>{
      DocName.projects: Document(name: DocName.projects, items: projects),
      DocName.inspirations: Document(name: DocName.inspirations, items: allInspirations),
      DocName.events: Document(name: DocName.events, items: events),
      DocName.tasks: Document(name: DocName.tasks, items: allTasks),
    },
    savedAt: _now.millisecondsSinceEpoch,
  );

  // 与「导出」同一套外层字段：导入时既能读 `collections`，也能认出自家导出文件
  final header = <String, dynamic>{
    'app': 'GuideLine',
    'kind': 'full-export',
    'exportedAt': _now.millisecondsSinceEpoch,
  };
  final text = Canonical.documentText(<String, dynamic>{...header, ...store.toJson()});

  // ---------------------------------------------------------------- 自检

  final issues = DecodeIssues();
  final parsed = StoreFile.parse(text, issues);
  if (!issues.isEmpty) {
    stderr.writeln('❌ 解析有 warning/error：');
    for (final w in issues.warnings) {
      stderr.writeln('  warn: $w');
    }
    for (final e in issues.errors) {
      stderr.writeln('  error: $e');
    }
    exit(1);
  }
  final roundTrip =
      Canonical.documentText(<String, dynamic>{...header, ...parsed.toJson()});
  if (roundTrip != text) {
    stderr.writeln('❌ 读入 → 写出不是逐字节一致（契约回归会挂）');
    exit(1);
  }

  final outDir = Directory('dist');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  final plain = File('dist/guideline-演示数据.json')..writeAsStringSync(text);
  final gz = File('dist/guideline-演示数据.json.gz')
    ..writeAsBytesSync(gzip.encode(utf8.encode(text)));

  int real(List<Entity> items) => items.where((e) => e is! Tombstone).length;
  int tombs(List<Entity> items) => items.whereType<Tombstone>().length;

  stdout.writeln('✅ 契约自检通过（零 warning / 零 error，读入写出逐字节一致）');
  stdout.writeln('   项目 ${real(projects)} 条（另 ${tombs(projects)} 条墓碑）');
  stdout.writeln('   灵感 ${real(allInspirations)} 条（另 ${tombs(allInspirations)} 条墓碑）');
  stdout.writeln('   事件 ${real(events)} 条（另 ${tombs(events)} 条墓碑）');
  stdout.writeln('   任务 ${real(allTasks)} 条（另 ${tombs(allTasks)} 条墓碑）');
  stdout.writeln('   ${plain.path}  ${(plain.lengthSync() / 1024).toStringAsFixed(1)} KB');
  stdout.writeln('   ${gz.path}  ${(gz.lengthSync() / 1024).toStringAsFixed(1)} KB');
}
