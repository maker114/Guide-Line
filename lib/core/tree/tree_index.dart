import '../ids.dart';
import '../models/entity.dart';
import '../models/project.dart';

/// 树索引：把扁平记录列表变成父 → 子索引，供完成判定、级联、归档区共用。
///
/// **约定**：索引用哪批节点，树算法就在哪批节点上工作。
/// 树形操作（深度、后代、环路）通常只关心**存活节点**，用 [TreeIndex.live] 构造。
class TreeIndex {
  TreeIndex(Iterable<EntityNode> nodes) : byId = <String, EntityNode>{}, _children = <String?, List<EntityNode>>{} {
    for (final node in nodes) {
      byId[node.id] = node;
    }
    for (final node in nodes) {
      final parentId = node.parentId;
      // 父节点不在这批节点里（例如父已被删除/归档）时，视作根，避免节点凭空消失
      final effectiveParent = (parentId != null && byId.containsKey(parentId)) ? parentId : null;
      _children.putIfAbsent(effectiveParent, () => <EntityNode>[]).add(node);
    }
    for (final list in _children.values) {
      list.sort((a, b) => compareByOrder(a.order, a.id, b.order, b.id));
    }
  }

  /// 只索引存活（未删除）节点。
  factory TreeIndex.live(Iterable<EntityNode> nodes) =>
      TreeIndex(nodes.where((n) => !n.deleted));

  final Map<String, EntityNode> byId;
  final Map<String?, List<EntityNode>> _children;

  List<EntityNode> get roots => List<EntityNode>.unmodifiable(_children[null] ?? const <EntityNode>[]);

  List<EntityNode> childrenOf(String? parentId) =>
      List<EntityNode>.unmodifiable(_children[parentId] ?? const <EntityNode>[]);

  /// 自身 + 全部后代（深度优先，先父后子）。
  List<EntityNode> subtreeOf(String id) {
    final out = <EntityNode>[];
    final node = byId[id];
    if (node == null) return out;
    final stack = <EntityNode>[node];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      out.add(current);
      final children = _children[current.id];
      if (children != null) {
        for (var i = children.length - 1; i >= 0; i -= 1) {
          stack.add(children[i]);
        }
      }
    }
    return out;
  }

  /// 全部后代（不含自身）。
  List<EntityNode> descendantsOf(String id) =>
      subtreeOf(id).where((n) => n.id != id).toList(growable: false);

  List<EntityNode> ancestorsOf(String id) {
    final out = <EntityNode>[];
    var current = byId[id];
    while (current != null && current.parentId != null) {
      final parent = byId[current.parentId];
      if (parent == null) break;
      out.add(parent);
      current = parent;
    }
    return out;
  }

  /// [id] 的**全名**：祖先名 + 自己，用 [separator] 连起来（如 `工作 · 发布 v1`）。
  ///
  /// 为什么要有它：项目树最多三层，而**孤零零一个项目名**说明不了它在哪一支里 ——
  /// 两个分类下各有一个「功能优化」时，光看那四个字根本分不出是哪一个
  /// （2026-10-07 用户要求：灵感条目下那半行要写全名）。
  ///
  /// 与 `ancestorsOf` 同源（一路读到根）。`id` 不在批内时按空串处理 ——
  /// 界面上宁可少一段前缀（调用方那边落到「未分配」），也不要因为一条悬挂引用
  /// 炸掉整个列表。
  String fullName(String id, {String separator = ' · '}) {
    final self = byId[id];
    if (self is! Project) return '';
    final names = <String>[
      for (final ancestor in ancestorsOf(id).reversed)
        if (ancestor is Project) ancestor.title,
      self.title,
    ];
    return names.join(separator);
  }

  /// 相对批内根节点的层级：根 = 1。
  int depthOf(String id) {
    if (!byId.containsKey(id)) return 0;
    return ancestorsOf(id).length + 1;
  }

  /// 把 [id] 的子树移到 [newParentId] 下是否会造成环（含移入自身）。
  bool wouldCreateCycle(String id, String? newParentId) {
    if (newParentId == null) return false;
    if (newParentId == id) return true;
    return ancestorsOf(newParentId).any((n) => n.id == id);
  }

  /// [id] 子树的最大层数（自身算 1 层）。
  int subtreeHeight(String id) {
    final children = _children[id] ?? const <EntityNode>[];
    if (children.isEmpty) return 1;
    var max = 0;
    for (final child in children) {
      final h = subtreeHeight(child.id);
      if (h > max) max = h;
    }
    return max + 1;
  }

  /// 判断把 [id] 移动到 [newParentId] 下之后，整体深度是否超过 [maxDepth]。
  bool fitsDepthLimit(String id, String? newParentId, int maxDepth) {
    final newAncestorDepth = newParentId == null ? 0 : depthOf(newParentId);
    return newAncestorDepth + subtreeHeight(id) <= maxDepth;
  }
}
