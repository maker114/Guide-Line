import '../core/ids.dart';
import '../core/json/document.dart';
import '../core/json/store_file.dart';
import '../core/models/entity.dart';
import '../core/models/enums.dart';
import '../core/models/event.dart';
import '../core/models/inspiration.dart';
import '../core/models/project.dart';
import '../core/models/task.dart';
import '../core/rules/archive_zone.dart';
import '../core/rules/cascade.dart';
import '../core/rules/completion.dart';
import '../core/store/app_storage.dart';
import '../core/store/ui_prefs.dart';
import '../core/tree/tree_index.dart';

/// 业务规则被违反（"用户不能这么做"），不是程序错误。
class RuleViolation implements Exception {
  const RuleViolation(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 搜索命中。
class SearchHit {
  const SearchHit({required this.doc, required this.entity, required this.matchedField});

  final DocName doc;
  final Entity entity;
  final String matchedField;

  String get displayTitle {
    final e = entity;
    if (e is Project) return e.title;
    if (e is Event) return e.name;
    if (e is Task) return e.title;
    if (e is Inspiration) return e.text;
    return e.id;
  }
}

/// 业务逻辑层：**内存单一数据源 + 全部业务规则**。
///
/// 职责：
///   · 维护 4 类集合的内存副本（唯一真源），所有 UI 读写都经过它；
///   · 承载全部业务规则（完成判定、级联、归档区、合并、彻底删除）；
///   · 每次变更后**原子落盘**（单文件 + 备份轮转，见 `AppStorage`）。
///
/// 单机形态下**没有任何网络/同步逻辑**（原双端方案的同步引擎已随归档搁置）。
class Workspace {
  Workspace._(this._storage, this._docs, this._prefs);

  factory Workspace.fromLoad(AppStorage storage, LoadReport report) {
    return Workspace._(
      storage,
      <DocName, Document>{
        for (final name in DocName.values) name: report.store.documentOf(name),
      },
      report.prefs,
    );
  }

  final AppStorage _storage;
  final Map<DocName, Document> _docs;
  UiPrefs _prefs;

  // ---------------------------------------------------------------- 只读视图

  Document documentOf(DocName name) => _docs[name] ?? Document.empty(name);

  UiPrefs get prefs => _prefs;

  Iterable<Project> get allProjects => documentOf(DocName.projects).projectItems;

  Iterable<Event> get allEvents => documentOf(DocName.events).eventItems;

  Iterable<Task> get allTasks => documentOf(DocName.tasks).taskItems;

  Iterable<Inspiration> get allInspirations => documentOf(DocName.inspirations).inspirationItems;

  List<Project> get liveProjects =>
      allProjects.where((p) => !p.deleted).toList(growable: false);

  List<Event> get liveEvents => allEvents.where((e) => !e.deleted).toList(growable: false);

  List<Task> get liveTasks => allTasks.where((t) => !t.deleted).toList(growable: false);

  List<Inspiration> get liveInspirations =>
      allInspirations.where((i) => !i.deleted).toList(growable: false);

  /// 灵感列表：按 `created_at` 倒序（设计文档 4.12）。
  List<Inspiration> get inspirationInbox {
    final list = liveInspirations.where((i) => i.isPending).toList(growable: false);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  TreeIndex get projectTree => TreeIndex.live(liveProjects);

  TreeIndex get taskTree => TreeIndex.live(liveTasks);

  ArchiveZone get archiveZone => deriveArchiveZone(
        projects: allProjects,
        events: allEvents,
        tasks: allTasks,
        inspirations: allInspirations,
      );

  Project? findProject(String id) => _firstWhere(allProjects, id);

  Event? findEvent(String id) => _firstWhere(allEvents, id);

  Task? findTask(String id) => _firstWhere(allTasks, id);

  Inspiration? findInspiration(String id) => _firstWhere(allInspirations, id);

  /// 某事件下的主线任务（`parent_task_id == null`），按 `order` 升序。
  List<Task> mainLineOf(String eventId) {
    final list = liveTasks
        .where((t) => t.eventId == eventId && t.parentId == null)
        .toList(growable: false);
    list.sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));
    return list;
  }

  /// 某任务（或某事件）的直接子任务。
  List<Task> subtasksOf(String? parentTaskId, {required String eventId}) {
    final list = liveTasks
        .where((t) => t.eventId == eventId && t.parentId == parentTaskId)
        .toList(growable: false);
    list.sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));
    return list;
  }

  /// 事件完成条件：所有参与判定的主线任务终态（设计文档 4.6）。
  CompletionCheck checkEventCompletion(String eventId) {
    final children = liveTasks
        .where((t) => t.eventId == eventId && t.parentId == null && !t.archived)
        .toList(growable: false);
    final unfinished = children.where((c) => !isTerminal(c.status)).length;
    return CompletionCheck(
      canComplete: unfinished == 0,
      judgedChildCount: children.length,
      unfinishedCount: unfinished,
    );
  }

  /// 到期聚合视图（Q29 / Q41 / Q48）：`due_at` 早于等于 [date] 且未完成、未归档。
  List<Task> tasksDueOnOrBefore(String date) {
    final list = liveTasks
        .where((t) =>
            !t.archived &&
            t.status == NodeStatus.pending &&
            t.dueAt != null &&
            t.dueAt!.compareTo(date) <= 0)
        .toList(growable: false);
    list.sort((a, b) {
      final byDate = a.dueAt!.compareTo(b.dueAt!);
      if (byDate != 0) return byDate;
      return compareByOrder(a.order, a.id, b.order, b.id);
    });
    return list;
  }

  /// 全局搜索（Q42）：只搜未归档、未删除；灵感只搜 `pending`。
  List<SearchHit> search(String query, {int limit = 100}) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <SearchHit>[];

    final hits = <SearchHit>[];
    bool hit(String? value, String field, DocName doc, Entity entity) {
      if (value != null && value.toLowerCase().contains(needle)) {
        hits.add(SearchHit(doc: doc, entity: entity, matchedField: field));
        return true;
      }
      return false;
    }

    for (final p in liveProjects) {
      if (p.archived) continue;
      if (hit(p.title, 'title', DocName.projects, p)) continue;
      if (hit(p.purpose, 'purpose', DocName.projects, p)) continue;
      hit(p.implementation, 'implementation', DocName.projects, p);
    }
    for (final e in liveEvents) {
      if (e.archived) continue;
      hit(e.name, 'name', DocName.events, e);
    }
    for (final t in liveTasks) {
      if (t.archived) continue;
      hit(t.title, 'title', DocName.tasks, t);
    }
    for (final i in liveInspirations) {
      if (!i.isPending) continue;
      hit(i.text, 'text', DocName.inspirations, i);
    }

    hits.sort((a, b) => b.entity.updatedAt.compareTo(a.entity.updatedAt));
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  // ---------------------------------------------------------------- 项目

  Project createProject({
    required String title,
    String? parentId,
    String purpose = '',
    String implementation = '',
    String? date,
  }) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw const RuleViolation('项目名不能为空');
    if (parentId != null) {
      final parent = findProject(parentId);
      if (parent == null || parent.deleted) throw const RuleViolation('父项目不存在');
      if (projectTree.depthOf(parentId) >= maxProjectDepth) {
        throw const RuleViolation('项目最多嵌套 $maxProjectDepth 层');
      }
    }

    final now = Ids.nowMillis();
    final project = Project(
      id: Ids.uuidV4(),
      title: trimmed,
      purpose: purpose,
      implementation: implementation,
      date: date,
      status: NodeStatus.pending,
      archived: false,
      parentProjectId: parentId,
      order: _nextOrder(_siblingOrders(DocName.projects, parentId)),
      completedAt: null,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    _upsert(DocName.projects, project);
    _touch(<DocName>[DocName.projects]);
    persist();
    return project;
  }

  void updateProject(
    String id, {
    String? title,
    String? purpose,
    String? implementation,
    Object? date = _unset,
    Object? parentId = _unset,
    bool? archived,
  }) {
    final project = findProject(id);
    if (project == null) throw const RuleViolation('项目不存在');
    if (title != null && title.trim().isEmpty) throw const RuleViolation('项目名不能为空');

    if (parentId != _unset) {
      final target = parentId as String?;
      final check = checkMove(
        index: projectTree,
        nodeId: id,
        newParentId: target,
        maxDepth: maxProjectDepth,
        crossEvent: false,
      );
      if (!check.allowed) throw RuleViolation(check.reason ?? '不能移动');
    }

    _upsert(
      DocName.projects,
      project.copyWith(
        title: title?.trim(),
        purpose: purpose,
        implementation: implementation,
        date: date,
        parentId: parentId,
        archived: archived,
        updatedAt: Ids.nowMillis(),
      ),
    );
    _touch(<DocName>[DocName.projects]);
    persist();
  }

  void setProjectStatus(String id, NodeStatus status) {
    final project = findProject(id);
    if (project == null) throw const RuleViolation('项目不存在');

    if (status == NodeStatus.done) {
      final check = checkCompletion(projectTree, id);
      if (!check.canComplete) throw RuleViolation(check.reason ?? '还有子节点未处理');
    }

    final now = Ids.nowMillis();
    _upsert(
      DocName.projects,
      project.copyWith(
        status: status,
        completedAt: status == NodeStatus.done ? now : null,
        updatedAt: now,
      ),
    );

    // 反向传播：变回非终态时，已完成的祖先必须退回（ADR-055）
    if (status == NodeStatus.pending) {
      for (final ancestor in projectTree.ancestorsOf(id)) {
        if (ancestor is Project && ancestor.status == NodeStatus.done) {
          _upsert(
            DocName.projects,
            ancestor.copyWith(status: NodeStatus.pending, completedAt: null, updatedAt: now),
          );
        }
      }
    }
    _touch(<DocName>[DocName.projects]);
    persist();
  }

  /// 归档 / 取消归档 —— **双向级联**（ADR-051）。
  void setProjectArchived(String id, bool archived) {
    final project = findProject(id);
    if (project == null) throw const RuleViolation('项目不存在');
    final ids = cascadeArchiveIds(projectTree, id, archived);
    final now = Ids.nowMillis();
    for (final pid in ids) {
      final p = findProject(pid);
      if (p != null) {
        _upsert(DocName.projects, p.copyWith(archived: archived, updatedAt: now));
      }
    }
    _touch(<DocName>[DocName.projects]);
    persist();
  }

  /// 删除项目：级联子项目；`pending` 灵感一并删除；`merged` 灵感**回退为未分配**（ADR-056）。
  ProjectDeletionPlan deleteProject(String id) {
    final project = findProject(id);
    if (project == null) throw const RuleViolation('项目不存在');

    final plan = planProjectDeletion(projectTree, allInspirations, id);
    final now = Ids.nowMillis();

    for (final pid in plan.projectIds) {
      final p = findProject(pid);
      if (p != null) _upsert(DocName.projects, p.copyWith(deleted: true, updatedAt: now));
    }
    for (final iid in plan.inspirationIdsToDelete) {
      final i = findInspiration(iid);
      if (i != null) _upsert(DocName.inspirations, i.copyWith(deleted: true, updatedAt: now));
    }
    for (final iid in plan.inspirationIdsToUnassign) {
      final i = findInspiration(iid);
      if (i != null) {
        _upsert(
          DocName.inspirations,
          i.copyWith(
            status: InspirationStatus.pending,
            projectId: null,
            mergedInto: null,
            mergedAt: null,
            updatedAt: now,
          ),
        );
      }
    }

    final touched = <DocName>{DocName.projects};
    if (plan.inspirationIdsToDelete.isNotEmpty || plan.inspirationIdsToUnassign.isNotEmpty) {
      touched.add(DocName.inspirations);
    }
    _touch(touched);
    persist();
    return plan;
  }

  // ---------------------------------------------------------------- 灵感

  Inspiration captureInspiration(String text, {String? projectId}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('灵感内容不能为空');
    if (projectId != null) {
      final project = findProject(projectId);
      if (project == null || project.deleted) throw const RuleViolation('目标项目不存在');
    }

    final now = Ids.nowMillis();
    final inspiration = Inspiration(
      id: Ids.uuidV4(),
      text: trimmed,
      projectId: projectId,
      status: InspirationStatus.pending,
      mergedInto: null,
      mergedAt: null,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    _upsert(DocName.inspirations, inspiration);
    _touch(<DocName>[DocName.inspirations]);
    persist();
    return inspiration;
  }

  void updateInspirationText(String id, String text) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('灵感内容不能为空');
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(text: trimmed, updatedAt: Ids.nowMillis()),
    );
    _touch(<DocName>[DocName.inspirations]);
    persist();
  }

  /// 分配到项目（`projectId = null` 表示解除分配）。
  void assignInspiration(String id, String? projectId) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    if (inspiration.isMerged) throw const RuleViolation('已合并的灵感不能改归属，请先撤销合并');
    if (projectId != null) {
      final project = findProject(projectId);
      if (project == null || project.deleted) throw const RuleViolation('目标项目不存在');
    }
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(projectId: projectId, updatedAt: Ids.nowMillis()),
    );
    _touch(<DocName>[DocName.inspirations]);
    persist();
  }

  void discardInspiration(String id) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(status: InspirationStatus.discarded, updatedAt: Ids.nowMillis()),
    );
    _touch(<DocName>[DocName.inspirations]);
    persist();
  }

  /// 从「已丢弃 / 已合并」恢复到待处理。
  void restoreInspiration(String id) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(
        status: InspirationStatus.pending,
        mergedInto: null,
        mergedAt: null,
        updatedAt: Ids.nowMillis(),
      ),
    );
    _touch(<DocName>[DocName.inspirations]);
    persist();
  }

  /// 合并灵感：写入项目正文 + 灵感置 `merged`（**跨文档**，ADR-033/037）。
  void mergeInspiration({
    required String inspirationId,
    required String projectId,
    required String newImplementation,
  }) {
    final inspiration = findInspiration(inspirationId);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    if (inspiration.isMerged) throw const RuleViolation('该灵感已合并');
    final project = findProject(projectId);
    if (project == null || project.deleted) throw const RuleViolation('目标项目不存在');

    final now = Ids.nowMillis();
    _upsert(
      DocName.projects,
      project.copyWith(implementation: newImplementation, updatedAt: now),
    );
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(
        status: InspirationStatus.merged,
        projectId: projectId,
        mergedInto: projectId,
        mergedAt: now,
        updatedAt: now,
      ),
    );
    _touch(<DocName>[DocName.projects, DocName.inspirations]);
    persist();
  }

  /// 撤销合并（ADR-057）：**只恢复灵感，不回滚项目正文**。
  void undoMerge(String inspirationId) {
    final inspiration = findInspiration(inspirationId);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    if (!inspiration.isMerged) throw const RuleViolation('该灵感不在已合并状态');

    final target = inspiration.mergedInto;
    final targetProject = target == null ? null : findProject(target);
    final projectAlive = targetProject != null && !targetProject.deleted;

    _upsert(
      DocName.inspirations,
      inspiration.copyWith(
        status: InspirationStatus.pending,
        mergedInto: null,
        mergedAt: null,
        projectId: projectAlive ? target : null,
        updatedAt: Ids.nowMillis(),
      ),
    );
    _touch(<DocName>[DocName.inspirations]);
    persist();
  }

  void deleteInspiration(String id) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    _upsert(DocName.inspirations, inspiration.copyWith(deleted: true, updatedAt: Ids.nowMillis()));
    _touch(<DocName>[DocName.inspirations]);
    persist();
  }

  // ---------------------------------------------------------------- 事件

  Event createEvent({required String name}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const RuleViolation('事件名不能为空');
    final now = Ids.nowMillis();
    final event = Event(
      id: Ids.uuidV4(),
      name: trimmed,
      status: NodeStatus.pending,
      archived: false,
      order: _nextOrder(_siblingOrders(DocName.events, null)),
      completedAt: null,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    _upsert(DocName.events, event);
    _touch(<DocName>[DocName.events]);
    persist();
    return event;
  }

  void updateEvent(String id, {String? name, bool? archived}) {
    final event = findEvent(id);
    if (event == null) throw const RuleViolation('事件不存在');
    if (name != null && name.trim().isEmpty) throw const RuleViolation('事件名不能为空');
    _upsert(
      DocName.events,
      event.copyWith(name: name?.trim(), archived: archived, updatedAt: Ids.nowMillis()),
    );
    _touch(<DocName>[DocName.events]);
    persist();
  }

  void setEventStatus(String id, NodeStatus status) {
    final event = findEvent(id);
    if (event == null) throw const RuleViolation('事件不存在');
    if (status == NodeStatus.done) {
      final check = checkEventCompletion(id);
      if (!check.canComplete) throw RuleViolation(check.reason ?? '还有任务未处理');
    }
    _upsert(
      DocName.events,
      event.copyWith(
        status: status,
        completedAt: status == NodeStatus.done ? Ids.nowMillis() : null,
        updatedAt: Ids.nowMillis(),
      ),
    );
    _touch(<DocName>[DocName.events]);
    persist();
  }

  /// 归档事件：**整条任务线一起归档**（跨文档）。
  void setEventArchived(String id, bool archived) {
    final event = findEvent(id);
    if (event == null) throw const RuleViolation('事件不存在');

    final now = Ids.nowMillis();
    _upsert(DocName.events, event.copyWith(archived: archived, updatedAt: now));

    final taskIndex = taskTree;
    final rootTasks = liveTasks
        .where((t) => t.eventId == id && t.parentId == null)
        .map((t) => t.id)
        .toList(growable: false);
    final ids = <String>{};
    for (final rootId in rootTasks) {
      ids.addAll(cascadeArchiveIds(taskIndex, rootId, archived));
    }
    for (final tid in ids) {
      final t = findTask(tid);
      if (t != null && t.archived != archived) {
        _upsert(DocName.tasks, t.copyWith(archived: archived, updatedAt: now));
      }
    }

    final touched = <DocName>{DocName.events};
    if (ids.isNotEmpty) touched.add(DocName.tasks);
    _touch(touched);
    persist();
  }

  /// 删除事件：事件 + **整条任务线**（跨文档）。
  Set<String> deleteEvent(String id) {
    final event = findEvent(id);
    if (event == null) throw const RuleViolation('事件不存在');
    final now = Ids.nowMillis();
    final taskIds = eventDeletionTaskIds(allTasks, id);

    _upsert(DocName.events, event.copyWith(deleted: true, updatedAt: now));
    for (final tid in taskIds) {
      final t = findTask(tid);
      if (t != null) _upsert(DocName.tasks, t.copyWith(deleted: true, updatedAt: now));
    }

    final touched = <DocName>{DocName.events};
    if (taskIds.isNotEmpty) touched.add(DocName.tasks);
    _touch(touched);
    persist();
    return taskIds;
  }

  // ---------------------------------------------------------------- 任务

  Task createTask({
    required String eventId,
    required String title,
    String? parentTaskId,
    TaskType type = TaskType.standard,
    String? dueAt,
  }) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw const RuleViolation('任务名不能为空');
    final event = findEvent(eventId);
    if (event == null || event.deleted) throw const RuleViolation('所属事件不存在');

    if (parentTaskId == null) {
      if (type != TaskType.standard) {
        throw const RuleViolation('主线任务必须是标准任务');
      }
    } else {
      final parent = findTask(parentTaskId);
      if (parent == null || parent.deleted) throw const RuleViolation('父任务不存在');
      if (parent.eventId != eventId) throw const RuleViolation('父任务属于其它事件');
      if (!parent.canHaveChild(type)) {
        throw RuleViolation('${parent.taskType.wire} 任务不能挂 ${type.wire} 子任务');
      }
      if (taskTree.depthOf(parentTaskId) + 1 > maxTaskDepth) {
        throw const RuleViolation('任务最多 $maxTaskDepth 层');
      }
    }

    final now = Ids.nowMillis();
    final task = Task(
      id: Ids.uuidV4(),
      eventId: eventId,
      parentTaskId: parentTaskId,
      taskType: type,
      title: trimmed,
      dueAt: dueAt,
      status: NodeStatus.pending,
      archived: false,
      order: _nextOrder(_siblingOrders(DocName.tasks, parentTaskId)),
      completedAt: null,
      createdAt: now,
      updatedAt: now,
      deleted: false,
    );
    _upsert(DocName.tasks, task);
    _touch(<DocName>[DocName.tasks]);

    // 新挂一个非终态子节点 → 已完成的祖先要退回（ADR-055）
    if (parentTaskId != null) {
      for (final target in parentsToRevertAfterInsert(taskTree, task.id)) {
        final t = findTask(target);
        if (t != null) {
          _upsert(DocName.tasks, t.copyWith(status: NodeStatus.pending, completedAt: null, updatedAt: now));
        }
      }
    }
    persist();
    return task;
  }

  void updateTask(String id, {String? title, Object? dueAt = _unset, TaskType? taskType}) {
    final task = findTask(id);
    if (task == null) throw const RuleViolation('任务不存在');
    if (title != null && title.trim().isEmpty) throw const RuleViolation('任务名不能为空');
    if (taskType != null && taskType != task.taskType) {
      final parent = task.parentId == null ? null : findTask(task.parentId!);
      if (parent == null && taskType != TaskType.standard) {
        throw const RuleViolation('主线任务必须是标准任务');
      }
      if (parent != null && !parent.canHaveChild(taskType)) {
        throw RuleViolation('${parent.taskType.wire} 任务不能挂 ${taskType.wire} 子任务');
      }
    }
    _upsert(
      DocName.tasks,
      task.copyWith(
        title: title?.trim(),
        dueAt: dueAt,
        taskType: taskType,
        updatedAt: Ids.nowMillis(),
      ),
    );
    _touch(<DocName>[DocName.tasks]);
    persist();
  }

  void setTaskStatus(String id, NodeStatus status) {
    final task = findTask(id);
    if (task == null) throw const RuleViolation('任务不存在');

    if (status == NodeStatus.done) {
      final check = checkCompletion(taskTree, id);
      if (!check.canComplete) throw RuleViolation(check.reason ?? '还有子任务未处理');
    }

    final now = Ids.nowMillis();
    _upsert(
      DocName.tasks,
      task.copyWith(
        status: status,
        completedAt: status == NodeStatus.done ? now : null,
        updatedAt: now,
      ),
    );

    final touched = <DocName>{DocName.tasks};
    if (status == NodeStatus.pending) {
      for (final ancestor in taskTree.ancestorsOf(id)) {
        if (ancestor is Task && ancestor.status == NodeStatus.done) {
          _upsert(
            DocName.tasks,
            ancestor.copyWith(status: NodeStatus.pending, completedAt: null, updatedAt: now),
          );
        }
      }
      final event = findEvent(task.eventId);
      if (event != null && event.status == NodeStatus.done) {
        _upsert(
          DocName.events,
          event.copyWith(status: NodeStatus.pending, completedAt: null, updatedAt: now),
        );
        touched.add(DocName.events);
      }
    }
    _touch(touched);
    persist();
  }

  void setTaskArchived(String id, bool archived) {
    final task = findTask(id);
    if (task == null) throw const RuleViolation('任务不存在');
    final ids = cascadeArchiveIds(taskTree, id, archived);
    final now = Ids.nowMillis();
    for (final tid in ids) {
      final t = findTask(tid);
      if (t != null) _upsert(DocName.tasks, t.copyWith(archived: archived, updatedAt: now));
    }
    _touch(<DocName>[DocName.tasks]);
    persist();
  }

  Set<String> deleteTask(String id) {
    final task = findTask(id);
    if (task == null) throw const RuleViolation('任务不存在');
    final ids = cascadeDeleteIds(taskTree, id);
    final now = Ids.nowMillis();
    for (final tid in ids) {
      final t = findTask(tid);
      if (t != null) _upsert(DocName.tasks, t.copyWith(deleted: true, updatedAt: now));
    }
    _touch(<DocName>[DocName.tasks]);
    persist();
    return ids;
  }

  /// 移动任务（含跨事件）。
  ///
  /// 跨事件移动时**父引用强制归零**（设计文档 4.11：禁止跨事件父子）——
  /// 调用方即便沿用旧父节点，也不会写出非法状态。
  void moveTask(String id, {String? newParentTaskId, String? newEventId}) {
    final task = findTask(id);
    if (task == null) throw const RuleViolation('任务不存在');
    final targetEvent = newEventId ?? task.eventId;
    if (findEvent(targetEvent) == null) throw const RuleViolation('目标事件不存在');

    final crossEvent = targetEvent != task.eventId;
    final parent = crossEvent ? null : newParentTaskId;

    if (parent != null) {
      final parentTask = findTask(parent);
      if (parentTask == null || parentTask.deleted) throw const RuleViolation('父任务不存在');
      if (parentTask.eventId != targetEvent) throw const RuleViolation('父任务属于其它事件');
      if (!parentTask.canHaveChild(task.taskType)) {
        throw RuleViolation(
          '${parentTask.taskType.wire} 任务不能挂 ${task.taskType.wire} 子任务',
        );
      }
    }

    final check = checkMove(
      index: taskTree,
      nodeId: id,
      newParentId: parent,
      maxDepth: maxTaskDepth,
      crossEvent: false,
    );
    if (!check.allowed) throw RuleViolation(check.reason ?? '不能移动');

    _upsert(
      DocName.tasks,
      task.copyWith(
        eventId: targetEvent,
        parentId: parent,
        order: _nextOrder(_siblingOrders(DocName.tasks, parent)),
        updatedAt: Ids.nowMillis(),
      ),
    );
    _touch(<DocName>[DocName.tasks]);
    persist();
  }

  /// 同一父节点下重排（传入期望顺序的 id 列表）。
  void reorder(DocName doc, String? parentId, List<String> orderedIds) {
    final now = Ids.nowMillis();
    var order = orderStep;
    for (final id in orderedIds) {
      switch (doc) {
        case DocName.projects:
          final project = findProject(id);
          if (project != null) _upsert(doc, project.copyWith(order: order, updatedAt: now));
          break;
        case DocName.tasks:
          final task = findTask(id);
          if (task != null) _upsert(doc, task.copyWith(order: order, updatedAt: now));
          break;
        case DocName.events:
          final event = findEvent(id);
          if (event != null) _upsert(doc, event.copyWith(order: order, updatedAt: now));
          break;
        case DocName.inspirations:
          break;
      }
      order += orderStep;
    }
    _touch(<DocName>[doc]);
    persist();
  }

  /// 彻底删除（ADR-052）：把墓碑**骨架化** —— 只保留 id / deleted / purged_at。
  void purge(DocName doc, Iterable<String> ids) {
    if (doc == DocName.inspirations && ids.isEmpty) return;
    final now = Ids.nowMillis();
    for (final id in ids) {
      _upsert(doc, Tombstone(id: id, purgedAt: now));
    }
    _touch(<DocName>[doc]);
    persist();
  }

  /// 归档区里「彻底删除」需要一起抹掉的 id。
  ///
  /// ⚠️ 这里**必须用包含墓碑的完整树**，且不能复用 `cascadeDeleteIds`
  /// （后者会跳过已删除节点，导致"已被级联删除的子树"收集为空，什么也删不掉）。
  Set<String> purgeIdsFor(DocName doc, String rootId) {
    switch (doc) {
      case DocName.projects:
        return TreeIndex(allProjects).subtreeOf(rootId).map((n) => n.id).toSet();
      case DocName.tasks:
        return TreeIndex(allTasks).subtreeOf(rootId).map((n) => n.id).toSet();
      case DocName.events:
        return <String>{
          rootId,
          ...allTasks.where((t) => t.eventId == rootId).map((t) => t.id),
        };
      case DocName.inspirations:
        return <String>{rootId};
    }
  }

  /// 从回收站恢复（**连同级联进来的后代一起恢复**）；返回实际恢复的 id 集合。
  ///
  /// 灵感是扁平实体，恢复的只有它自己；项目/任务/事件会连同后代一起回来。
  Set<String> restoreFromTrash(DocName doc, String rootId) {
    final now = Ids.nowMillis();
    final restored = <String>{};

    switch (doc) {
      case DocName.projects:
        for (final node in TreeIndex(allProjects).subtreeOf(rootId)) {
          final project = findProject(node.id);
          if (project != null && project.deleted) {
            _upsert(doc, project.copyWith(deleted: false, updatedAt: now));
            restored.add(project.id);
          }
        }
        break;
      case DocName.tasks:
        for (final node in TreeIndex(allTasks).subtreeOf(rootId)) {
          final task = findTask(node.id);
          if (task != null && task.deleted) {
            _upsert(doc, task.copyWith(deleted: false, updatedAt: now));
            restored.add(task.id);
          }
        }
        break;
      case DocName.events:
        final event = findEvent(rootId);
        if (event != null && event.deleted) {
          _upsert(doc, event.copyWith(deleted: false, updatedAt: now));
          restored.add(event.id);
        }
        for (final task in allTasks.where((t) => t.eventId == rootId && t.deleted).toList()) {
          _upsert(DocName.tasks, task.copyWith(deleted: false, updatedAt: now));
          restored.add(task.id);
        }
        break;
      case DocName.inspirations:
        final inspiration = findInspiration(rootId);
        if (inspiration != null && inspiration.deleted) {
          _upsert(doc, inspiration.copyWith(deleted: false, updatedAt: now));
          restored.add(inspiration.id);
        }
        break;
    }

    if (restored.isNotEmpty) {
      _touch(<DocName>[doc]);
      if (doc == DocName.events) _touch(<DocName>[DocName.tasks]);
      persist();
    }
    return restored;
  }

  // ---------------------------------------------------------------- 视图偏好

  /// 记录一次显式展开 / 收起（默认值由 UI 按节点状态算，不写进偏好）。
  void setExpanded(String id, {required bool expanded}) {
    _prefs = _prefs.withExpanded(id, expanded: expanded);
    _storage.savePrefs(_prefs);
  }

  void setLastTab(int index) {
    if (_prefs.lastTabIndex == index) return;
    _prefs = _prefs.copyWith(lastTabIndex: index);
    _storage.savePrefs(_prefs);
  }

  /// 记下"刚刚成功导出过"（用于「超过 7 天没导出」的提醒）。
  void markExported(int millis) {
    _prefs = _prefs.copyWith(lastExportedAt: millis);
    _storage.savePrefs(_prefs);
  }

  /// 直接替换整套界面偏好并落盘。
  ///
  /// 外观类改动（主题 / 背景图 / 不透明度 / 模糊）又多又碎，
  /// 逐个写 setter 不划算，统一走这里。
  void updatePrefs(UiPrefs next) {
    _prefs = next;
    _storage.savePrefs(_prefs);
  }

  int? get lastExportedAt => _prefs.lastExportedAt;

  /// 数据目录（供设置页展示）
  String get dataDirectoryPath => _storage.paths.describe();

  /// 当前的完整数据快照（导出用）。
  StoreFile buildStoreFile() => StoreFile(documents: _docs, savedAt: Ids.nowMillis());

  /// 内存快照 + 回滚。
  ///
  /// 业务动作的写法是「先改内存，再整份落盘」。写盘失败时内存已经改了，
  /// 如果就这么放过，界面会显示一个**磁盘上并不存在**的状态 —— 用户以为存住了，
  /// 下次启动才发现没了。所以写失败必须把内存退回动作前的样子，让两边保持一致。
  ///
  /// `Document` 是不可变的，`_docs` 是「整份替换」而不是就地改，
  /// 因此浅拷贝一份 map 就是完整快照。
  Map<DocName, Document> snapshotInMemory() => Map<DocName, Document>.from(_docs);

  void rollbackTo(Map<DocName, Document> snapshot) {
    _docs
      ..clear()
      ..addAll(snapshot);
  }

  /// 原子落盘：**整份数据一次写入**（单文件让跨实体变更天然原子）。
  void persist() {
    _storage.save(buildStoreFile());
    _storage.savePrefs(_prefs);
  }

  /// 手动触发一次备份轮转（导入、批量操作前可调用）。
  void snapshotNow() {
    _storage.save(buildStoreFile());
  }

  // ---------------------------------------------------------------- 内部

  int _nextOrder(Iterable<int> siblings) {
    var max = 0;
    for (final value in siblings) {
      if (value > max) max = value;
    }
    return max + orderStep;
  }

  Iterable<int> _siblingOrders(DocName doc, String? parentId) sync* {
    switch (doc) {
      case DocName.projects:
        for (final p in allProjects) {
          if (!p.deleted && p.parentId == parentId) yield p.order;
        }
        break;
      case DocName.tasks:
        for (final t in allTasks) {
          if (!t.deleted && t.parentId == parentId) yield t.order;
        }
        break;
      case DocName.events:
        for (final e in allEvents) {
          if (!e.deleted) yield e.order;
        }
        break;
      case DocName.inspirations:
        break;
    }
  }

  T? _firstWhere<T extends Entity>(Iterable<T> list, String id) {
    for (final item in list) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _upsert(DocName name, Entity entity) {
    final items = List<Entity>.from(documentOf(name).items);
    final index = items.indexWhere((e) => e.id == entity.id);
    if (index >= 0) {
      items[index] = entity;
    } else {
      items.add(entity);
    }
    _docs[name] = documentOf(name).copyWith(items: items);
  }

  /// 单机形态下"触碰"不再需要事务记录：整份数据一次原子写入，
  /// 跨实体变更（例如合并灵感同时改项目与灵感）天然是全有或全无。
  void _touch(Iterable<DocName> names) {
    // 保留该调用点是为了让业务代码的语义（"这次改了哪几类集合"）显式可见；
    // 单文件存储下无需额外处理。
  }
}

const Object _unset = Object();
