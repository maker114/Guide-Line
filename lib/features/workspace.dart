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
import '../core/models/project_palette.dart';
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

/// 「并列任务」已经废除：它是当年"框内并排两条线"的做法，与
/// "一条线就是一件事的脉络"这条主线是两套心智。
///
/// 这里只是**不再允许新建 / 改写**；老文件里已有的 `parallel` 记录照旧读得进来、
/// 照旧能改能删（《数据契约》§7 禁止删枚举值，删了会静默改写老数据）。
/// 拒绝时把替代做法一并说出来，免得用户以为"这个功能坏了"。
const String _parallelGone =
    '「并列任务」已废除 —— 两件并行的事请开两个「事件」，'
    '或者把两条并成同一个节点下的两条子任务';

/// 「正文与进来时一模一样」时拒绝合并的文案（Q8）。
///
/// 界面上最该看到的那一句就是这个 —— 它同时是两个可点动作的名字，
/// 所以抽成常量、界面与业务层共用一份，免得两处说法慢慢走偏。
const String implementationUnchanged =
    '正文没有变化，这条灵感还没写进项目 —— 用「追加原文」或「作为清单条目」';

/// 分类的汇总（Q2）—— **只统计，不判定**。
///
/// 口径（与《定义与边界》§2.1 / §2.2 一致，只用契约里已有的字段）：
///   · [targetCount]：这棵子树下**目标**（没有未归档、未删除下级项目的项目）的个数；
///   · [itemTotal] / [itemDone]：这些目标的「实现清单」条目总数与已勾选数。
///
/// 为什么不是「N 条事件 / N 条未完成任务」：任务属于**事件**，而事件与项目之间
/// **没有关联字段**（《数据契约》§3.3：事件没有 `parent_*`，也没有"所属项目"）。
/// 要按项目数事件，得先给事件加一个「所属项目」—— 那是数据契约变更，
/// 本轮明确不做，也不许为了凑进度发明新字段。
/// 所以退到**目标自己的可交付口径**：清单条目的勾选进度。它只是把各个目标里
/// 已经在显示的数字加起来，不参与完成判定，也不与事件里的任务联动。
class CategorySummary {
  const CategorySummary({
    required this.targetCount,
    required this.itemTotal,
    required this.itemDone,
  });

  /// 子树下的目标个数（叶子项目）。
  final int targetCount;

  /// 这些目标的「实现清单」条目总数。
  final int itemTotal;

  /// 其中已勾选的条数。
  final int itemDone;
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

/// 全局搜索一次最多返回多少条（`Workspace.search` 的默认 [limit]，搜索页文案也用它）。
const int searchHitLimit = 100;

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

  /// 灵感列表：**未处理、且所属项目没有归档**，按 `created_at` 倒序（设计文档 4.12）。
  ///
  /// 「项目归档了，挂在它下面的灵感照旧列在这儿」曾经是个前后不一致的缺陷
  /// （Q10）：项目归档的确认框承诺"这些灵感会从列表里隐藏"，归档区也写着
  /// "不占用灵感列表"，只有灵感页照旧把它们一条条摆出来。
  /// 口径统一到**隐藏**这一侧，隐藏了多少条由
  /// [inspirationsHiddenByArchivedProjects] 给同一个数。
  List<Inspiration> get inspirationInbox {
    final hidden = _inspirationIdsHiddenByArchivedProjects();
    final list = liveInspirations
        .where((i) => i.isPending && !hidden.contains(i.id))
        .toList(growable: false);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// 因**所属项目已归档**（含其子项目）而从灵感列表里隐藏的待处理灵感条数。
  ///
  /// 灵感页（"另有 N 条在已归档项目下"）与归档区「被隐藏」分区**用同一个数** ——
  /// 两处各数一遍，迟早出现"页头说 3 条、归档区列 2 条"。归档区那份
  /// （`deriveArchiveZone`）也调这一个口径。
  int get inspirationsHiddenByArchivedProjects =>
      _inspirationIdsHiddenByArchivedProjects().length;

  /// 被归档项目遮住的灵感 id 集合（含**子项目**：归档是双向级联，
  /// 子项目也跟着归档，它们名下的灵感自然一起隐藏）。
  ///
  /// **判据是"它所在的这条祖先链上有人归档了"**，不是"`projectTree` 的子树里有它" ——
  /// 归档是双向级联，一个原本单独归档、后来又跟着父项目归档的子项目，会在
  /// `projectTree` 里因为父节点也在而**掉出子树根**；只看子树就会漏掉它名下的灵感。
  /// 从每个已归档项目往上走一遍祖先链，才能把所有遮住灵感的项目都收齐。
  ///
  /// 只按 `project_id` 判：`merged_into` 指向的项目归档与否不影响 ——
  /// 已合并的灵感本来就在归档区「已合并」里，不进灵感列表。
  Set<String> _inspirationIdsHiddenByArchivedProjects() {
    final archived = <String>{
      for (final project in liveProjects)
        if (project.archived) project.id,
    };
    if (archived.isEmpty) return const <String>{};

    final tree = projectTree;
    bool underArchived(String projectId) {
      if (archived.contains(projectId)) return true;
      for (final ancestor in tree.ancestorsOf(projectId)) {
        if (archived.contains(ancestor.id)) return true;
      }
      return false;
    }

    return <String>{
      for (final inspiration in liveInspirations)
        if (inspiration.isPending &&
            inspiration.projectId != null &&
            underArchived(inspiration.projectId!))
          inspiration.id,
    };
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
  ///
  /// **已归档的节点不在里面**（Q18）。以前这里把归档的也列出来，于是同一个框里
  /// 出现两套数：「下级 1/3」把归档的算进分母，而"能不能勾"用的判据（
  /// [isTaskBlocked] / `checkEventCompletion`）却把它排除 —— 分母永远等不上。
  /// 现在**显示与判定同一套取数**，`下级 d/t`、「另有 N 个已完成节点」、
  /// 折叠提示与"锁"全跟着它走。
  List<Task> mainLineOf(String eventId) {
    final list = liveTasks
        .where((t) => t.eventId == eventId && t.parentId == null && !t.archived)
        .toList(growable: false);
    list.sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));
    return list;
  }

  /// 某任务（或某事件）的直接子任务；**已归档的同样排除**（与 [mainLineOf] 同源）。
  List<Task> subtasksOf(String? parentTaskId, {required String eventId}) {
    final list = liveTasks
        .where((t) =>
            t.eventId == eventId && t.parentId == parentTaskId && !t.archived)
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

  /// 事件「已完成」的自动一致性（Q29）：**只允许自动退回，不允许自动完成**。
  ///
  /// 任何会改变"某事件下参与判定的主线任务集合"的动作（新建任务、把任务移进某个
  /// 事件、取消归档、从回收站恢复……）之后调用一次：如果这个事件当前是 `done`，
  /// 而它已经**不满足完成条件**（还有非终态的主线任务），就把它退回 `pending`
  /// 并清掉 `completedAt` —— 否则会留下"已完成但 0/1"这种自相矛盾的状态。
  ///
  /// **已搁置（`ignored`）的事件一律不动**：搁置是用户显式选择，不是算出来的。
  /// 反向也绝不发生：任务全部终态时**不会**自动把事件标成完成。
  void _revertIncompleteDoneEvents(Iterable<String> eventIds, int now) {
    for (final eventId in eventIds.toSet()) {
      final event = findEvent(eventId);
      if (event == null || event.deleted) continue;
      if (event.status != NodeStatus.done) continue;
      if (checkEventCompletion(eventId).canComplete) continue;
      _upsert(
        DocName.events,
        event.copyWith(status: NodeStatus.pending, completedAt: null, updatedAt: now),
      );
    }
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

  /// **已逾期**的权威取数（Q19）：这是"我还欠着什么"里**已经晚了**的那一部分。
  ///
  /// 口径：**未完成（`pending`）+ 未归档 + 有到期日 + 到期日早于今天**。
  ///
  /// 三处必须同源 —— 外壳的逾期横幅、底部「更多」的角标、以及点进去的
  /// 「接下来的任务」页里「已逾期」那一组的行数：它们**只有这一个函数**。
  /// 这个项目上出过恰恰相反的事：横幅与角标把"已搁置事件下的任务"排除掉，
  /// 而落点页面照 `openTasks()` 分组，用户数不出横幅说的那几条。
  ///
  /// **已搁置的事件下的任务仍然不计入**，这是唯一一处与 [openTasks] 不同的地方：
  ///   · 搁置 = "这条线先不做了"，再拉响逾期角标与启动横幅，等于把放下的东西
  ///     又拽回来催一遍（2026-09-25 实机反馈）；
  ///   · 于是这一页上它们**不落在「已逾期」组里**（分组时按同一份 id 集合切分），
  ///     而是单独一档、日期也不标红 —— 页头的数与组的行数因此永远对得上。
  ///
  /// 反过来说：**"这一页要不要显示搁置线的任务"始终是"要"**（[openTasks] 不排除），
  /// 这份函数只回答"哪几条算逾期"。
  List<Task> overdueTasks() {
    final today = Ids.todayDate();
    final mutedEventIds = _mutedEventIds();
    final list = liveTasks
        .where((t) =>
            !t.archived &&
            t.status == NodeStatus.pending &&
            t.dueAt != null &&
            t.dueAt!.isNotEmpty &&
            // 严格早于今天：今天到期的不算"逾期"（它是"今天"，urgency.dart 的另一档）
            t.dueAt!.compareTo(today) < 0 &&
            !mutedEventIds.contains(t.eventId))
        .toList(growable: false);
    list.sort((a, b) {
      final byDate = a.dueAt!.compareTo(b.dueAt!);
      if (byDate != 0) return byDate;
      return compareByOrder(a.order, a.id, b.order, b.id);
    });
    return list;
  }

  /// 「接下来的任务」用的一览：**还开着的任务** —— 未完成、未归档，
  /// **不管有没有排到期日，也不管所属事件是不是已搁置**。
  ///
  /// ⚠️ 这里**故意不像 [overdueTasks] 那样跳过已搁置的事件**
  /// （2026-09-25 实机反馈确认）：那一页是用户主动打开的任务一览，
  /// 他要看到全部还欠着的；被隐藏的 9 条任务让整页空空如也，查了半天才发现
  /// 是这条规则。**"放下的线不该继续催"只在"催"的地方生效**。
  List<Task> openTasks() => liveTasks
      .where((t) => !t.archived && t.status == NodeStatus.pending)
      .toList(growable: false);

  /// 不再参与"催办"的事件 id（已搁置就是"这条线先不做了"）。
  Set<String> _mutedEventIds() => allEvents
      .where((e) => e.status == NodeStatus.ignored)
      .map((e) => e.id)
      .toSet();

  /// 某事件是否**不再参与到期统计**（已搁置）。
  ///
  /// 界面用它把日期颜色降下来：既然不计入「到期」，就不该在这里显示成逾期红。
  bool isEventMutedForDue(String eventId) =>
      findEvent(eventId)?.status == NodeStatus.ignored;

  /// **能搜到的东西有几条**（Q20）：与 [search] 的扫描范围**同一套判据** ——
  /// 未删除、未归档的项目 / 事件 / 任务，加上未删除、**待处理**的灵感。
  ///
  /// 为什么要有这个函数：「更多」入口原来写着「N 条内容可搜（不含已归档）」，
  /// 而那个 N 是"含已归档"的四个 getter 加出来的；点进去的搜索页又只搜未归档。
  /// 入口与页面共用一个数，限定词才不会跟算法打架。
  int get searchableContentCount {
    var count = 0;
    for (final p in liveProjects) {
      if (!p.archived) count += 1;
    }
    for (final e in liveEvents) {
      if (!e.archived) count += 1;
    }
    for (final t in liveTasks) {
      if (!t.archived) count += 1;
    }
    for (final i in liveInspirations) {
      if (i.isPending) count += 1;
    }
    return count;
  }

  /// 全局搜索（Q42）：只搜未归档、未删除；灵感只搜 `pending`。
  ///
  /// 返回**按 `updatedAt` 倒序**的命中，最多 [limit] 条（默认 [searchHitLimit]）。
  /// 调用方若还要知道"是不是被截断了"，**传一个更大的 limit 自己比** ——
  /// 不要改成"返回条数大于 limit 就说明还有"，那与这里的截断语义相反。
  List<SearchHit> search(String query, {int limit = searchHitLimit}) {
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
      // 新项目**自动分配一个标志色**：空着的话项目树里全是同一个灰图标，
      // 一眼分不出谁是谁。取"还没被用的"颜色里第一个，用完一轮再从头来 ——
      // 这样同一层的兄弟项目优先拿到不同的颜色。
      color: nextProjectColor(),
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

  // 项目**没有**「完成 / 搁置」（《定义与边界》§2.1，2026-09-26 决定）：
  //   · `Project.status` / `completedAt` 只**只读保留** —— 老数据里已经标过的
  //     `done` / `ignored` 原样留在文件里（读入→写出逐字节不变），界面不再显示，
  //     业务层也**不再产生新值**（新建项目写 `pending` / `null`）；
  //   · 于是"父项目什么时候算完成""父项目为什么还不能完成"这类问题整体消失，
  //     原来的 `setProjectStatus`（含 `checkCompletion(projectTree, …)` 与
  //     为它服务的祖先退回）**整段删除**；
  //   · 项目只回答"要 / 不要"：不需要了就**归档**。想表达"做完了"，说到事件的
  //     三态上去 —— 完成规则（§4）只对**事件与任务**生效。

  /// 一个项目的**未归档、未删除的直属下级项目**。
  ///
  /// 角色判据只看这一条（《定义与边界》§2.1）：**有下级 = 分类，没有下级 = 目标**，
  /// 与深度无关；已归档的下级不算数（它已经"不看了"，不该继续把父项目撑成分类）。
  List<Project> childProjectsOf(String projectId) => projectTree
      .childrenOf(projectId)
      .whereType<Project>()
      .where((p) => !p.archived)
      .toList(growable: false);

  /// 这个项目是不是**分类**（有下级）。口径与 [childProjectsOf] 同源。
  bool isProjectCategory(String projectId) => childProjectsOf(projectId).isNotEmpty;

  /// 分类的汇总，口径见 [CategorySummary]（只统计，不判定）。
  ///
  /// 目标 = 子树下**没有未归档下级**的项目；一个目标的"可交付"就是它自己的
  /// 实现清单，所以汇总把各目标的清单条目与勾选数加起来。
  CategorySummary summarizeCategory(String projectId) {
    final tree = projectTree;
    var targets = 0;
    var itemTotal = 0;
    var itemDone = 0;

    for (final node in tree.subtreeOf(projectId)) {
      if (node.id == projectId) continue; // 自己不是自己的目标
      if (node is! Project || node.archived) continue;
      final hasLiveChild = tree
          .childrenOf(node.id)
          .whereType<Project>()
          .any((child) => !child.archived);
      if (hasLiveChild) continue; // 还有下级 → 它自己也是分类
      targets += 1;
      itemTotal += node.items.length;
      itemDone += node.itemsDoneCount;
    }

    return CategorySummary(
      targetCount: targets,
      itemTotal: itemTotal,
      itemDone: itemDone,
    );
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

  // ---------------------------------------------------------------- 标志色

  /// 自动分配给新项目的标志色：取当前**用得最少**的那个，同数时按色板顺序。
  ///
  /// 为什么不是"随机"也不是"按创建顺序轮着来"：
  ///   · 随机会出现相邻两个项目撞色，正是要避免的；
  ///   · 单纯轮转在删过项目之后会继续往下走，很快又撞上。
  /// 取"用得最少"能让颜色分布自动均衡，删项目也会自然把它让出来。
  ///
  /// 色板只有一份（`ProjectPalette.hexes`）—— 界面的取色器与这里的自动分配共用，
  /// 不各写一份（放在 core 是因为 features 不能依赖 ui）。
  String nextProjectColor() => _leastUsedColor(liveProjects.map((p) => p.color));

  /// 事件标识色：同一个算法，统计的是事件。
  ///
  /// 事件与项目共用一份色板 —— 它们从不出现在同一个列表里，不需要两套色，
  /// 而共用能让"这根竖条是什么颜色 = 什么东西"的印象保持一致。
  String nextEventColor() => _leastUsedColor(liveEvents.map((e) => e.color));

  /// 取**用得最少**的那个色板色：删掉几条之后颜色会自然让出来，不会一直往下轮。
  String _leastUsedColor(Iterable<String?> colors) {
    final used = <String, int>{};
    for (final color in colors) {
      if (color == null) continue;
      used[color] = (used[color] ?? 0) + 1;
    }
    var best = ProjectPalette.hexes.first;
    var bestCount = used[best] ?? 0;
    for (final color in ProjectPalette.hexes.skip(1)) {
      final count = used[color] ?? 0;
      if (count < bestCount) {
        best = color;
        bestCount = count;
      }
    }
    return best;
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
    if (inspiration.isMerged) throw const RuleViolation('已合并的灵感不能改归属，请先恢复为待处理');
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
      if (inspiration.isMerged) throw const RuleViolation('已合并的灵感不能改归属，请先恢复为待处理');
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

  /// 把一条灵感**原封不动**追加到项目「如何解决」的末尾（灵感整理第 7 条）。
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

  /// 合并灵感 · **落点一：写进「如何解决」正文**（跨文档，ADR-033/037）。
  ///
  /// 合并编辑器里"照着灵感手改正文"与"追加原文后保存"走的都是这一条。
  /// 空正文拒绝 —— 合并不该把正文清没（要只留清单条目就走
  /// [mergeInspirationAsItem]）。
  ///
  /// **正文没变也拒绝**（Q8）：这条灵感在项目里一个字都没多，
  /// 却会被标成 `merged`、从灵感箱里消失 —— 用户拿到的是"合并没有发生"，
  /// 界面却报成功。要"追加一段"就走 [appendToImplementation]，
  /// 要"变成一条待办"就走 [mergeInspirationAsItem]。
  void mergeInspiration({
    required String inspirationId,
    required String projectId,
    required String newImplementation,
  }) {
    final inspiration = _requireMergeable(inspirationId, projectId);
    final trimmed = newImplementation.trim();
    if (trimmed.isEmpty) throw const RuleViolation('正文不能是空的');
    final project = findProject(projectId)!;
    if (trimmed == project.implementation) {
      throw const RuleViolation(implementationUnchanged);
    }

    final now = Ids.nowMillis();
    _upsert(
      DocName.projects,
      project.copyWith(implementation: trimmed, updatedAt: now),
    );
    _markInspirationMerged(inspiration, projectId, now);
    persist();
  }

  /// 合并灵感 · **落点二：追加成「实现清单」的新一条**（合并编辑器里那个
  /// 「作为清单条目」按钮）。
  ///
  /// 不碰 `implementation`：这条灵感的去向是"一件要做的事"，不是往说明里添一句。
  ProjectItem mergeInspirationAsItem({
    required String inspirationId,
    required String projectId,
    required String itemText,
  }) {
    final inspiration = _requireMergeable(inspirationId, projectId);
    final trimmed = itemText.trim();
    if (trimmed.isEmpty) throw const RuleViolation('条目内容不能为空');
    final project = findProject(projectId)!;

    final now = Ids.nowMillis();
    final item = ProjectItem(id: Ids.uuidV4(), text: trimmed, done: false);
    _upsert(
      DocName.projects,
      project.copyWith(
        items: <ProjectItem>[...project.items, item],
        updatedAt: now,
      ),
    );
    _markInspirationMerged(inspiration, projectId, now);
    persist();
    return item;
  }

  /// 两种合并共用的前置检查：灵感在、目标项目在、这条灵感还没合并过。
  Inspiration _requireMergeable(String inspirationId, String projectId) {
    final inspiration = findInspiration(inspirationId);
    if (inspiration == null) throw const RuleViolation('灵感不存在');
    if (inspiration.isMerged) throw const RuleViolation('该灵感已合并');
    final project = findProject(projectId);
    if (project == null || project.deleted) throw const RuleViolation('目标项目不存在');
    return inspiration;
  }

  /// 两种合并共用的收尾：灵感置 `merged` 并记下合并到哪。
  ///
  /// 只 `_upsert` 不 `persist()` —— 由调用方跟项目那次改动**一起落盘**，
  /// 这样"灵感状态 + 正文/条目"要么都在、要么都不在。
  void _markInspirationMerged(Inspiration inspiration, String projectId, int now) {
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
  }

  /// 把已合并的灵感**恢复为待处理**（ADR-057，Q9 定的叫法）：
  /// **只恢复灵感，项目里的内容不退回**。
  ///
  /// 合并是"吸收"：写进「如何解决」的那一行、追加进「实现清单」的那一条
  /// 都已经属于项目了，这个动作不去把它们拿走（拿走了才是真的数据丢失）。
  /// 所以界面上的名字必须带上这半句 —— 叫"撤销合并"会让人以为项目也退回去了，
  /// 用户再合并一次就得到重复内容。
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
      // 与项目一样自动分配一个标识色（"用得最少"的那个）
      color: nextEventColor(),
    );
    _upsert(DocName.events, event);
    persist();
    return event;
  }

  /// 设 / 清事件标识色（与 [setProjectColor] 同一套口径）。
  void setEventColor(String id, String? color) {
    final event = findEvent(id);
    if (event == null) throw const RuleViolation('事件不存在');
    final normalized = Canonical.normalizeHexColor(color);
    if (color != null && normalized == null) {
      throw const RuleViolation('标识色要写成 #rrggbb');
    }
    if (normalized == event.color) return;
    _upsert(
      DocName.events,
      event.copyWith(color: normalized, updatedAt: Ids.nowMillis()),
    );
    persist();
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
  }) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw const RuleViolation('任务名不能为空');
    if (type == TaskType.parallel) throw const RuleViolation(_parallelGone);
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

    // 新挂一个非终态子节点 → 已完成的祖先要退回（ADR-055）
    if (parentTaskId != null) {
      for (final target in parentsToRevertAfterInsert(taskTree, task.id)) {
        final t = findTask(target);
        if (t != null) {
          _upsert(DocName.tasks, t.copyWith(status: NodeStatus.pending, completedAt: null, updatedAt: now));
        }
      }
    }

    // 事件这层同样要退回（Q29）：往"已完成"的事件里加任务（主线或子任务）之后，
    // 它已经不满足完成条件了。子任务那条路会先把父任务退回，这里再收口到事件。
    _revertIncompleteDoneEvents(<String>[eventId], now);
    persist();
    return task;
  }

  // ---------------------------------------------------------------- 任务线（一条链）

  /// 一条任务线就是**一条链**：主线节点按 `order` 依次往下走，每个节点可挂子任务。
  ///
  /// 这里删掉过一整套走向边（`setTaskNext` / `addTaskNext` / `removeTaskNext` /
  /// `materializeTaskChain`）：分叉 / 合流要用户先理解"支路 / 分叉点 / 合流点"
  /// 三个概念，与"快速理清一件事的脉络"冲突。并行两条线请**开两个事件**。

  /// 把一条主线节点挪到链路的下一个位置（上移 / 下移）。
  ///
  /// 顺序是本层唯一的排序信息，所以"插到某处"= 交换相邻两个节点的 `order`。
  void moveTaskWithinLine(String id, {required bool up}) {
    final task = findTask(id);
    if (task == null || task.deleted) throw const RuleViolation('任务不存在');
    if (task.parentId != null) throw const RuleViolation('只有主线节点在链上');

    final line = mainLineOf(task.eventId);
    final index = line.indexWhere((each) => each.id == id);
    final target = up ? index - 1 : index + 1;
    if (index < 0 || target < 0 || target >= line.length) return;

    final other = line[target];
    final now = Ids.nowMillis();
    _upsert(DocName.tasks, task.copyWith(order: other.order, updatedAt: now));
    _upsert(DocName.tasks, other.copyWith(order: task.order, updatedAt: now));
    persist();
  }

  void updateTask(String id, {String? title, Object? dueAt = _unset, TaskType? taskType}) {
    final task = findTask(id);
    if (task == null) throw const RuleViolation('任务不存在');
    if (title != null && title.trim().isEmpty) throw const RuleViolation('任务名不能为空');
    if (taskType == TaskType.parallel) throw const RuleViolation(_parallelGone);
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

    // 取消归档会把一条主线任务**重新拉回判定域**（Q29）：已完成的事件若因此
    // 不再满足条件，同样退回。
    _revertIncompleteDoneEvents(<String>[task.eventId], now);
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

    // 移进 / 移出 / 改变归属都会动到"某事件下参与判定的主线任务集合"（Q29）：
    // 移出的事件不再多一条，移进的事件可能从此不再满足完成条件 —— 两头都收口。
    _revertIncompleteDoneEvents(<String>[task.eventId, targetEvent], Ids.nowMillis());
    persist();
  }

  /// 彻底删除（ADR-052）：把墓碑**骨架化** —— 只保留 id / deleted / purged_at。
  void purge(DocName doc, Iterable<String> ids) {
    final count = _skeletonize(doc, ids);
    if (count > 0) persist();
  }

  /// 清掉**超过 [trashRetentionDays] 天**的墓碑（骨架化），返回清掉的记录条数。
  ///
  /// 在启动时调用一次（`AppController.bootstrap`）：回收站不能无限增长，
  /// 也没人会专门去点"清理"。
  ///
  /// 口径：**所有墓碑**都只留 30 天 —— 包括灵感。灵感删除后不进回收站
  /// （它是扁平实体，见 `deriveArchiveZone`），但它的墓碑同样只在文件里留 30 天，
  /// 否则"删除的数据只保存 30 天"这条口径就有个看不见的例外。
  ///
  /// 只抹墓碑、不碰活着的节点：子树里若真有活节点（理论上不会），留着不动。
  int purgeExpiredTrash({DateTime? now}) {
    final expired = <DocName, Set<String>>{};

    void collect(DocName doc, Iterable<Entity> nodes, Entity? Function(String id) find) {
      final ids = <String>{};
      for (final node in nodes) {
        if (!node.deleted) continue;
        if (trashDaysLeft(node.updatedAt, now: now) > 0) continue; // 还没到期
        for (final id in purgeIdsFor(doc, node.id)) {
          final target = find(id);
          if (target == null || target.deleted) ids.add(id);
        }
      }
      if (ids.isNotEmpty) expired[doc] = ids;
    }

    collect(DocName.projects, allProjects, findProject);
    collect(DocName.events, allEvents, findEvent);
    collect(DocName.tasks, allTasks, findTask);
    collect(DocName.inspirations, allInspirations, findInspiration);

    if (expired.isEmpty) return 0;

    final purgedAt = Ids.nowMillis();
    var count = 0;
    for (final entry in expired.entries) {
      // 四个集合的清理**一次落盘**：中途失败不该留下"清了一半"的状态
      count += _skeletonize(entry.key, entry.value, purgedAt: purgedAt);
    }
    persist();
    return count;
  }

  /// 把一个集合里的这些 id 换成墓碑（不落盘，由调用方决定什么时候 persist）。
  int _skeletonize(DocName doc, Iterable<String> ids, {int? purgedAt}) {
    final now = purgedAt ?? Ids.nowMillis();
    var count = 0;
    for (final id in ids) {
      _upsert(doc, Tombstone(id: id, purgedAt: now));
      count += 1;
    }
    return count;
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
        final restoredEventIds = <String>{};
        for (final node in TreeIndex(allTasks).subtreeOf(rootId)) {
          final task = findTask(node.id);
          if (task != null && task.deleted) {
            _upsert(doc, task.copyWith(deleted: false, updatedAt: now));
            restored.add(task.id);
            restoredEventIds.add(task.eventId);
          }
        }
        // 恢复出来的任务会重新回到判定域（Q29）：已完成的事件若不再满足条件就退回
        _revertIncompleteDoneEvents(restoredEventIds, now);
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
        // 事件连同它那条任务线一起回来（Q29）：若恢复出的主线任务里有非终态的，
        // 事件不能再自称"已完成"
        _revertIncompleteDoneEvents(<String>[rootId], now);
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
  ///
  /// ⚠️ 走的是**强制**路径（`forceRotate: true`），不是普通 `save`：
  /// 普通保存的轮转按"编辑会话 / 最小间隔"节流（Q3），而这里正是**用户显式
  /// 要求"现在留一份"**的场景 —— 被节流拦下就等于这句承诺落空。
  void snapshotNow() {
    _storage.save(buildStoreFile(), forceRotate: true);
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
