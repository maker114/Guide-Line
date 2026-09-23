import '../ids.dart';
import '../models/task.dart';

/// 任务线的**流图**：主线上的走向（分叉 / 合流）。
///
/// 为什么需要它：原来「主线」是 `parent_task_id == null` 的**兄弟链**，
/// 顺序完全由 `order` 决定，只能一路往下走；并列任务被建模成主线任务的
/// **子节点**，因此只能分叉、无法合流。要做到"两条主线各自往下走、
/// 最后再接回同一个任务"，树上表达不了 —— 必须有**显式的后续边**
/// （`Task.nextIds`，契约字段 `next_task_ids`）。
///
/// 几条刻意的设计：
///   · **兼容老数据**：整条线都没有显式边时，按 `order` 合成顺序边，
///     行为与改动前完全一致（老文件不需要迁移就能继续打开）；
///   · **指向不存在的任务的边直接忽略**，不会让节点凭空消失；
///   · **有环就整体退回按 `order` 的链**：宁可画成一条直线，也不能死循环；
///   · 这里只做图上的事，不碰存储、不碰界面。
class TaskFlow {
  // 位置参数 + 初始化形参：私有字段不能做具名参数，所以这里只能用位置参数
  const TaskFlow._(
    this.all,
    this._byId,
    this._next,
    this._prev,
    this._layers,
    this.usesExplicitEdges,
    this.hasCycle,
  );

  /// 按 `order` 排好的主线任务（含已归档，是否显示由界面决定）。
  final List<Task> all;

  final Map<String, Task> _byId;
  final Map<String, List<String>> _next;
  final Map<String, List<String>> _prev;
  final Map<String, int> _layers;

  /// 这条线用的是显式后续边（true）还是按 `order` 合成的链（false）。
  final bool usesExplicitEdges;

  /// 数据里存在环，已退回按 `order` 的链。
  final bool hasCycle;

  static const TaskFlow empty = TaskFlow._(
    <Task>[],
    <String, Task>{},
    <String, List<String>>{},
    <String, List<String>>{},
    <String, int>{},
    false,
    false,
  );

  factory TaskFlow.of(Iterable<Task> allTasks, {required String eventId}) {
    final nodes = allTasks
        .where((task) => task.eventId == eventId && !task.deleted && task.parentId == null)
        .toList(growable: false)
      ..sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));
    if (nodes.isEmpty) return TaskFlow.empty;

    final byId = <String, Task>{for (final task in nodes) task.id: task};
    final explicit = nodes.any((task) => task.nextIds.isNotEmpty);

    var next = _edgesFrom(nodes, byId, explicit: explicit);
    final cyclic = _hasCycle(nodes, next);
    if (cyclic) {
      // 有环时不修单条边，整体退回链 —— 局部修补很容易留下"看似能走、其实绕圈"的图
      next = _edgesFrom(nodes, byId, explicit: false);
    }

    final prev = <String, List<String>>{for (final task in nodes) task.id: <String>[]};
    for (final entry in next.entries) {
      for (final target in entry.value) {
        prev[target]!.add(entry.key);
      }
    }

    final layers = _computeLayers(nodes, prev);

    return TaskFlow._(
      List<Task>.unmodifiable(nodes),
      byId,
      next,
      prev,
      layers,
      explicit && !cyclic,
      cyclic,
    );
  }

  static Map<String, List<String>> _edgesFrom(
    List<Task> nodes,
    Map<String, Task> byId, {
    required bool explicit,
  }) {
    final next = <String, List<String>>{};
    if (explicit) {
      for (final task in nodes) {
        // 指向不存在的任务的边直接丢掉：忽略比"整条线崩掉"好
        next[task.id] = task.nextIds
            .where((id) => id != task.id && byId.containsKey(id))
            .toList(growable: false);
      }
      return next;
    }
    for (var i = 0; i < nodes.length; i += 1) {
      next[nodes[i].id] = i + 1 < nodes.length
          ? <String>[nodes[i + 1].id]
          : const <String>[];
    }
    return next;
  }

  /// 三色 DFS 找环。
  static bool _hasCycle(List<Task> nodes, Map<String, List<String>> next) {
    const visiting = 1;
    const done = 2;
    final state = <String, int>{};

    for (final start in nodes) {
      if (state[start.id] == done) continue;
      final stack = <({String id, int index})>[(id: start.id, index: 0)];
      state[start.id] = visiting;
      while (stack.isNotEmpty) {
        final frame = stack.last;
        final targets = next[frame.id] ?? const <String>[];
        if (frame.index >= targets.length) {
          state[frame.id] = done;
          stack.removeLast();
          continue;
        }
        stack[stack.length - 1] = (id: frame.id, index: frame.index + 1);
        final target = targets[frame.index];
        final targetState = state[target];
        if (targetState == visiting) return true;
        if (targetState == done) continue;
        state[target] = visiting;
        stack.add((id: target, index: 0));
      }
    }
    return false;
  }

  /// 分层 = 从根出发的最长路径长度。保证"分叉出去的节点在同一层或更靠后"，
  /// 渲染时按层排布就能自然表达先后。
  static Map<String, int> _computeLayers(
    List<Task> nodes,
    Map<String, List<String>> prev,
  ) {
    final layers = <String, int>{};
    int layerOf(String id) {
      final cached = layers[id];
      if (cached != null) return cached;
      layers[id] = 0; // 先占位，防止万一还有环时无限递归
      var best = 0;
      for (final parent in prev[id] ?? const <String>[]) {
        final candidate = layerOf(parent) + 1;
        if (candidate > best) best = candidate;
      }
      layers[id] = best;
      return best;
    }

    for (final task in nodes) {
      layerOf(task.id);
    }
    return layers;
  }

  bool get isEmpty => all.isEmpty;

  Task? taskOf(String id) => _byId[id];

  /// 入口节点（没有前驱）。孤立节点也算，否则它会从界面上消失。
  List<Task> get roots => _byOrder(
        all.where((task) => (_prev[task.id] ?? const <String>[]).isEmpty),
      );

  /// 出口节点（没有后继）。
  List<Task> get sinks => _byOrder(
        all.where((task) => (_next[task.id] ?? const <String>[]).isEmpty),
      );

  List<Task> successorsOf(String id) =>
      _byOrder((_next[id] ?? const <String>[]).map((each) => _byId[each]).whereType<Task>());

  List<Task> predecessorsOf(String id) =>
      _byOrder((_prev[id] ?? const <String>[]).map((each) => _byId[each]).whereType<Task>());

  int successorCountOf(String id) => (_next[id] ?? const <String>[]).length;

  int predecessorCountOf(String id) => (_prev[id] ?? const <String>[]).length;

  bool isFork(String id) => successorCountOf(id) > 1;

  bool isJoin(String id) => predecessorCountOf(id) > 1;

  bool get hasFork => all.any((task) => isFork(task.id));

  bool get hasJoin => all.any((task) => isJoin(task.id));

  int layerOf(String id) => _layers[id] ?? 0;

  int get layerCount =>
      all.isEmpty ? 0 : all.map((task) => layerOf(task.id)).reduce((a, b) => a > b ? a : b) + 1;

  /// 按层分组的节点（层内按 `order`），渲染时逐层往下排。
  List<List<Task>> get layers => <List<Task>>[
        for (var i = 0; i < layerCount; i += 1)
          _byOrder(all.where((task) => layerOf(task.id) == i)),
      ];

  /// 加一条 `from → to` 的后续边会不会成环（含自环）。
  ///
  /// 界面在"接回某个任务"时必须先问这一句，否则用户能造出环来。
  bool wouldCreateCycle({required String fromId, required String toId}) {
    if (fromId == toId) return true;
    // 从 to 出发能不能走回 from
    final seen = <String>{};
    final stack = <String>[toId];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      if (current == fromId) return true;
      if (!seen.add(current)) continue;
      stack.addAll(_next[current] ?? const <String>[]);
    }
    return false;
  }

  static List<Task> _byOrder(Iterable<Task> tasks) {
    final out = tasks.toList(growable: false)
      ..sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));
    return out;
  }
}
