import '../core/ids.dart';
import '../core/json/canonical.dart';
import '../core/json/document.dart';
import '../core/json/store_file.dart';
import '../core/models/entity.dart';
import '../core/models/enums.dart';
import '../core/models/event.dart';
import '../core/models/inspiration.dart';
import '../core/models/project.dart';
import '../core/models/project_item.dart';
import '../core/models/task.dart';
import '../core/rules/archive_zone.dart';
import '../core/rules/cascade.dart';
import '../core/rules/completion.dart';
import '../core/store/app_storage.dart';
import '../core/store/ui_prefs.dart';
import '../core/tree/task_flow.dart';
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

  /// 任务是否**当前不能勾选**（还有未处理的直接子任务）。
  ///
  /// 与 [setTaskStatus] 的拒绝条件同源（都看"参与判定的直接子任务"），
  /// 但刻意**不建 tree**：任务行每帧都会问一次，`taskTree` 是整棵树重建，代价不对。
  /// 传 [unfinished] 时用调用方已经算好的下级汇总，连筛选都省掉。
  bool isTaskBlocked(String taskId, {int? unfinished}) {
    final task = findTask(taskId);
    if (task == null) return false;
    if (unfinished != null) return unfinished > 0;
    return liveTasks.any((t) =>
        t.eventId == task.eventId &&
        t.parentId == taskId &&
        !t.archived &&
        !isTerminal(t.status));
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
    persist();
    return inspiration;
  }

  /// 改标签（灵感整理第 5 条）。传入的内容会按契约口径清洗：去空格、丢空串、去重。
  void updateInspirationTags(String id, Iterable<String> tags) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    final cleaned = <String>[];
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isEmpty || cleaned.contains(trimmed)) continue;
      cleaned.add(trimmed);
    }
    if (_sameList(cleaned, inspiration.tags)) return; // 没变就不写盘
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(tags: cleaned, updatedAt: Ids.nowMillis()),
    );
    persist();
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 设 / 清项目标识色（灵感整理第 10 条）。传 `null` 或非法值表示清空。
  void setProjectColor(String id, String? color) {
    final project = findProject(id);
    if (project == null) throw const RuleViolation('项目不存在');
    final normalized = Canonical.normalizeHexColor(color);
    if (color != null && normalized == null) {
      throw const RuleViolation('标识色要写成 #rrggbb');
    }
    if (normalized == project.color) return;
    _upsert(
      DocName.projects,
      project.copyWith(color: normalized, updatedAt: Ids.nowMillis()),
    );
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
    persist();
  }

  /// 改灵感正文（灵感整理第 2 条）。
  ///
  /// 空内容一律拒绝并保持原值 —— 与界面层的"必填项被清空时不提交"是同一条约定，
  /// 这里再挡一次，免得别的调用点绕过去把灵感清成空串。
  void updateInspirationText(String id, String text) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('灵感内容不能为空');
    if (trimmed == inspiration.text) return; // 没变就不写盘
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(text: trimmed, updatedAt: Ids.nowMillis()),
    );
    persist();
  }

  /// 把一条灵感**原封不动**追加到项目「实现」的末尾（灵感整理第 7 条）。
  ///
  /// 纯文本拼接，不改契约：已有实现非空时先补一个换行，再把原文按原样放上去。
  /// 刻意**不做任何润色或改写** —— 用户要的是"原文作为新的一行"。
  static String appendToImplementation(String implementation, String inspirationText) {
    final base = implementation.trimRight();
    final addition = inspirationText.trim();
    if (addition.isEmpty) return base;
    if (base.isEmpty) return addition;
    return '$base\n$addition';
  }

  /// 批量分配（`projectId = null` 表示解除分配）。
  ///
  /// 规则与单条 [assignInspiration] 一致：已合并的不能改归属。
  /// **先整体校验再落盘**，失败时一条都不动 —— 逐条调用会让每次 `persist()`
  /// 都重写整份文件并轮转备份，批量场景下既慢又危险。
  void assignInspirations(Iterable<String> ids, String? projectId) {
    final list = ids.toList(growable: false);
    if (list.isEmpty) return;

    final targets = <Inspiration>[];
    for (final id in list) {
      final inspiration = findInspiration(id);
      if (inspiration == null) throw const RuleViolation('灵感不存在');
      if (inspiration.isMerged) throw const RuleViolation('已合并的灵感不能改归属，请先撤销合并');
      targets.add(inspiration);
    }
    if (projectId != null) {
      final project = findProject(projectId);
      if (project == null || project.deleted) throw const RuleViolation('目标项目不存在');
    }

    final now = Ids.nowMillis();
    for (final inspiration in targets) {
      _upsert(
        DocName.inspirations,
        inspiration.copyWith(projectId: projectId, updatedAt: now),
      );
    }
    persist();
  }

  /// 批量丢弃。
  void discardInspirations(Iterable<String> ids) {
    final now = Ids.nowMillis();
    for (final id in ids) {
      final inspiration = findInspiration(id);
      if (inspiration == null) continue;
      _upsert(
        DocName.inspirations,
        inspiration.copyWith(status: InspirationStatus.discarded, updatedAt: now),
      );
    }
    persist();
  }

  /// 批量删除（墓碑，可从回收站恢复）。
  void deleteInspirations(Iterable<String> ids) {
    final now = Ids.nowMillis();
    for (final id in ids) {
      final inspiration = findInspiration(id);
      if (inspiration == null) continue;
      _upsert(DocName.inspirations, inspiration.copyWith(deleted: true, updatedAt: now));
    }
    persist();
  }

  void discardInspiration(String id) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    _upsert(
      DocName.inspirations,
      inspiration.copyWith(status: InspirationStatus.discarded, updatedAt: Ids.nowMillis()),
    );
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
    persist();
  }

  void deleteInspiration(String id) {
    final inspiration = findInspiration(id);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    _upsert(DocName.inspirations, inspiration.copyWith(deleted: true, updatedAt: Ids.nowMillis()));
    persist();
  }

  // ---------------------------------------------------------------- 实现清单

  /// 把一段正文按行拆成清单条目（**显式动作**，不在读取时自动拆）。
  ///
  /// 只在"清单为空"时由界面调用：把一段中文按行拆开是**不可逆的猜测**
  /// （用户可能一段就是一条），自动拆等于第一次打开就悄悄改了数据形态。
  /// 行首的 `-` / `*` / `1.` 这类记号会被去掉，空行丢弃。
  static List<String> splitImplementationLines(String implementation) {
    final out = <String>[];
    for (final rawLine in implementation.split('\n')) {
      var line = rawLine.trim();
      if (line.isEmpty) continue;
      line = line.replaceFirst(RegExp(r'^[-*+]\s+'), '');
      line = line.replaceFirst(RegExp(r'^\d+[.)]\s+'), '');
      line = line.trim();
      if (line.isEmpty) continue;
      out.add(line);
    }
    return out;
  }

  ProjectItem addProjectItem(String projectId, String text) {
    final project = _requireProject(projectId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('条目内容不能为空');

    final item = ProjectItem(id: Ids.uuidV4(), text: trimmed, done: false);
    _writeItems(project, <ProjectItem>[...project.items, item]);
    return item;
  }

  void updateProjectItemText(String projectId, String itemId, String text) {
    final project = _requireProject(projectId);
    final index = _itemIndex(project, itemId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('条目内容不能为空');
    if (project.items[index].text == trimmed) return; // 没变就不写盘

    final next = <ProjectItem>[...project.items];
    next[index] = next[index].copyWith(text: trimmed);
    _writeItems(project, next);
  }

  void setProjectItemDone(String projectId, String itemId, bool done) {
    final project = _requireProject(projectId);
    final index = _itemIndex(project, itemId);
    if (project.items[index].done == done) return;

    final next = <ProjectItem>[...project.items];
    next[index] = next[index].copyWith(done: done);
    _writeItems(project, next);
  }

  void removeProjectItem(String projectId, String itemId) {
    final project = _requireProject(projectId);
    _itemIndex(project, itemId); // 不存在就抛，避免静默什么都没发生
    _writeItems(
      project,
      project.items.where((i) => i.id != itemId).toList(growable: false),
    );
  }

  /// 上移 / 下移一条。[delta] 只接受 `-1` 与 `1`；已经在两端时是空操作。
  void moveProjectItem(String projectId, String itemId, int delta) {
    if (delta != -1 && delta != 1) {
      throw const RuleViolation('一次只能上移或下移一位');
    }
    final project = _requireProject(projectId);
    final index = _itemIndex(project, itemId);
    final target = index + delta;
    if (target < 0 || target >= project.items.length) return; // 到头了，什么也不做

    final next = <ProjectItem>[...project.items];
    final moved = next.removeAt(index);
    next.insert(target, moved);
    _writeItems(project, next);
  }

  /// 把正文按行拆成条目。**只在清单为空时允许** —— 否则会把已有条目顶掉。
  int splitImplementationIntoItems(String projectId) {
    final project = _requireProject(projectId);
    if (project.items.isNotEmpty) {
      throw const RuleViolation('已经有条目了，先把清单清空再拆');
    }
    final lines = splitImplementationLines(project.implementation);
    if (lines.isEmpty) throw const RuleViolation('正文里没有可拆成条目的内容');

    _writeItems(
      project,
      <ProjectItem>[
        for (final line in lines) ProjectItem(id: Ids.uuidV4(), text: line, done: false),
      ],
    );
    return lines.length;
  }

  /// 清空清单（**只清清单，不动正文**）。
  ///
  /// 给"拆错了想重来"用：拆完不满意时可以清掉再拆一次。
  void clearProjectItems(String projectId) {
    final project = _requireProject(projectId);
    if (project.items.isEmpty) return;
    _writeItems(project, const <ProjectItem>[]);
  }

  /// 用整理后的正文替换「实现」文本（AI 整理写回走这里）。
  void replaceImplementation(String projectId, String text) {
    final project = _requireProject(projectId);
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const RuleViolation('整理结果不能是空的');
    if (trimmed == project.implementation) return;
    _upsert(
      DocName.projects,
      project.copyWith(implementation: trimmed, updatedAt: Ids.nowMillis()),
    );
    persist();
  }

  Project _requireProject(String projectId) {
    final project = findProject(projectId);
    if (project == null || project.deleted) throw const RuleViolation('项目不存在');
    return project;
  }

  int _itemIndex(Project project, String itemId) {
    final index = project.items.indexWhere((i) => i.id == itemId);
    if (index < 0) throw const RuleViolation('条目不存在');
    return index;
  }

  void _writeItems(Project project, List<ProjectItem> items) {
    _upsert(
      DocName.projects,
      project.copyWith(items: items, updatedAt: Ids.nowMillis()),
    );
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
    String? linkAfterTaskId,
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

    // 「接在某个任务之后」时，必须**先**把隐式链固化，再插入新任务：
    // 这一步会写入显式边，而显式边一出现，整条线就改按显式边解释 ——
    // 顺序反了的话，其余节点会瞬间失去顺序（这正是 materialize 要防的坑）。
    // 也不能在插入新任务之后再固化：那时新任务已经在图里，会被错误地串进链尾。
    if (parentTaskId == null && linkAfterTaskId != null) {
      materializeTaskChain(eventId);
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

    // 主线新任务要接进走向里，否则它会变成"没有前驱的孤立入口"，看起来像凭空多一条线。
    // （按 order 成链的模式不用管：顺序本来就由 order 决定。）
    if (parentTaskId == null) {
      final anchor = linkAfterTaskId == null ? null : findTask(linkAfterTaskId);
      if (anchor != null && anchor.parentId == null && anchor.eventId == eventId) {
        // 明确要求接在某个任务之后（"在这里分叉 / 接上一个新任务"）
        _upsert(
          DocName.tasks,
          anchor.copyWith(nextIds: _dedupe(<String>[...anchor.nextIds, task.id]), updatedAt: now),
        );
      } else {
        // 默认接在当前所有出口之后（链式模式下这一步等价于"排到最后"）
        final flow = TaskFlow.of(allTasks, eventId: eventId);
        if (flow.usesExplicitEdges) {
          for (final tail in flow.sinks.where((each) => each.id != task.id)) {
            _upsert(
              DocName.tasks,
              tail.copyWith(nextIds: _dedupe(<String>[...tail.nextIds, task.id]), updatedAt: now),
            );
          }
        }
      }
    }

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

  // ---------------------------------------------------------------- 任务走向（分叉 / 合流）

  /// 把主线的「按 `order` 的隐式链」**固化成显式后续边**。
  ///
  /// 第一次做分叉 / 接回之前**必须**先调它：`TaskFlow` 的规则是"整条线只要有一个
  /// 显式边，就全部按显式边解释"，所以直接加一条边会让其余节点瞬间失去隐式链、
  /// 散成一堆孤立入口。这里先把现有链整段写下来，用户再加边就不会有这种副作用。
  void materializeTaskChain(String eventId) {
    final flow = TaskFlow.of(allTasks, eventId: eventId);
    if (flow.isEmpty || flow.usesExplicitEdges || flow.hasCycle) return;

    final now = Ids.nowMillis();
    var changed = false;
    for (final task in flow.all) {
      final next = flow.successorsOf(task.id).map((each) => each.id).toList(growable: false);
      if (_sameIds(task.nextIds, next)) continue;
      _upsert(DocName.tasks, task.copyWith(nextIds: next, updatedAt: now));
      changed = true;
    }
    if (changed) {
      persist();
    }
  }

  /// 设置某条主线任务的后续边（一次设一组）。
  ///
  /// 校验：必须是主线任务、目标同事件且也是主线、不能接自己、不能成环；
  /// 重复项直接去掉。
  void setTaskNext(String id, List<String> nextIds) {
    final task = findTask(id);
    if (task == null || task.deleted) throw const RuleViolation('任务不存在');
    if (task.parentId != null) throw const RuleViolation('只有主线任务能接后续');

    // 先把隐式链固化，否则"加一条边"会让其它节点失去顺序
    materializeTaskChain(task.eventId);

    final unique = <String>[];
    for (final nextId in nextIds) {
      if (nextId == id) throw const RuleViolation('不能接到自己后面');
      if (unique.contains(nextId)) continue;
      final target = findTask(nextId);
      if (target == null || target.deleted) throw const RuleViolation('要接的任务不存在');
      if (target.eventId != task.eventId) throw const RuleViolation('不能接到其它事件的任务后面');
      if (target.parentId != null) throw const RuleViolation('只能接到主线任务后面');
      unique.add(nextId);
    }

    if (TaskFlow.wouldCycleIfChanged(
      allTasks,
      eventId: task.eventId,
      taskId: id,
      nextIds: unique,
    )) {
      throw const RuleViolation('这样接会绕成一个环');
    }

    _upsert(
      DocName.tasks,
      task.copyWith(nextIds: List<String>.unmodifiable(unique), updatedAt: Ids.nowMillis()),
    );
    persist();
  }

  /// 追加一条后续边：本来没有后续就是"接着做"，本来有后续就成了**分叉**。
  void addTaskNext(String id, String nextId) =>
      setTaskNext(id, <String>[..._nextIdsAfterMaterialize(id), nextId]);

  /// 断开一条后续边（合流处断掉一条，就退回单线）。
  void removeTaskNext(String id, String nextId) => setTaskNext(
        id,
        _nextIdsAfterMaterialize(id).where((each) => each != nextId).toList(growable: false),
      );

  /// 取"固化隐式链**之后**"的后续边。
  ///
  /// 增删一条边都是"在现有走向上加/减一项"，所以基准值必须是**固化后**的那一份。
  /// 先读 `task.nextIds` 再进 `setTaskNext` 是错的：那时隐式链还没写下来（读到空表），
  /// 固化出来的原有顺序会被这一次写入**整条覆盖掉** —— 表现就是"接一条新的，
  /// 原来那条后续凭空消失"。这里踩过一次，`test/ui/task_link_next_test.dart` 就是为它加的。
  List<String> _nextIdsAfterMaterialize(String id) {
    final task = findTask(id);
    if (task == null || task.deleted) throw const RuleViolation('任务不存在');
    materializeTaskChain(task.eventId);
    // 固化会改这一行，必须重新读，不能接着用上面那个旧对象
    return findTask(id)?.nextIds ?? const <String>[];
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<String> _dedupe(List<String> ids) {
    final out = <String>[];
    for (final id in ids) {
      if (!out.contains(id)) out.add(id);
    }
    return out;
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
      }
    }
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
    persist();
  }

  /// 彻底删除（ADR-052）：把墓碑**骨架化** —— 只保留 id / deleted / purged_at。
  void purge(DocName doc, Iterable<String> ids) {
    if (doc == DocName.inspirations && ids.isEmpty) return;
    final now = Ids.nowMillis();
    for (final id in ids) {
      _upsert(doc, Tombstone(id: id, purgedAt: now));
    }
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
}

const Object _unset = Object();
