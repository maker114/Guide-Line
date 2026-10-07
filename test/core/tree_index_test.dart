import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/tree/tree_index.dart';

/// `TreeIndex` 的公开树算法（T-8）：`descendantsOf` / `depthOf` 的**未知 id 分支**
/// 此前零覆盖 —— 而"查一个不存在的 id"在真实数据里天天发生（墓碑、被删的父引用、
/// 数据损坏后的悬挂引用）。
void main() {
  Project node(String id, {String? parent}) => Project(
        id: id,
        title: id,
        purpose: '',
        implementation: '',
        date: null,
        status: NodeStatus.pending,
        archived: false,
        parentProjectId: parent,
        order: 1000,
        completedAt: null,
        createdAt: 1788652800000,
        updatedAt: 1788652800000,
        deleted: false,
      );

  final index = TreeIndex(<Project>[
    node('root'),
    node('a', parent: 'root'),
    node('a1', parent: 'a'),
    node('b', parent: 'root'),
    node('gone', parent: '不存在的父'),
  ]);

  group('descendantsOf', () {
    test('返回整棵子树的子孙（不含自己），深度不限', () {
      expect(
        index.descendantsOf('root').map((n) => n.id).toSet(),
        <String>{'a', 'a1', 'b'},
      );
      expect(index.descendantsOf('a').map((n) => n.id).toList(), <String>['a1']);
      expect(index.descendantsOf('a1'), isEmpty, reason: '叶子没有子孙');
    });

    test('未知 id → 空列表，而不是抛错', () {
      expect(index.descendantsOf('从来没有过这个 id'), isEmpty);
    });

    test('父引用指向不存在的节点：**视作根**，不会凭空消失', () {
      // 构造函数把"父不在这批节点里"规范成 `null`（源码注释："避免节点凭空消失"）——
      // 所以悬挂引用的节点挂在**根**这一层：它是 roots 之一，
      // 但**不属于** `root` 的子树（它不是 root 的孩子）。
      expect(index.roots.map((n) => n.id), contains('gone'));
      expect(index.descendantsOf('root').map((n) => n.id), isNot(contains('gone')));
      expect(index.childrenOf(null).map((n) => n.id), contains('gone'));
      expect(index.childrenOf('不存在的父'), isEmpty, reason: '那个键根本不会被建出来');
    });
  });

  group('depthOf', () {
    test('根是第 1 层，往下递增', () {
      expect(index.depthOf('root'), 1);
      expect(index.depthOf('a'), 2);
      expect(index.depthOf('a1'), 3);
    });

    test('父引用指向不存在的节点时，仍算作第 1 层（悬挂引用不炸）', () {
      // `gone` 的父 id 在集合里不存在 —— 契约 §4.3 说这种悬挂引用由上层按规则处理，
      // 但树算法本身必须给一个确定的答案，不能抛。
      expect(index.depthOf('gone'), 1);
    });
  });

  group('roots / childrenOf', () {
    test('roots 含"父为 null"与"父不存在"两类', () {
      expect(index.roots.map((n) => n.id).toSet(), <String>{'root', 'gone'});
    });

    test('childrenOf(null) 与 roots 同义；未知父返回空', () {
      expect(
        index.childrenOf(null).map((n) => n.id).toSet(),
        index.roots.map((n) => n.id).toSet(),
      );
      expect(index.childrenOf('从来没有过这个 id'), isEmpty);
    });
  });

  group('fullName（全名，2026-10-07）', () {
    // 样本里每个节点的 `title` 就等于它的 id，读起来更直白。
    test('根只有自己；两层写"父 · 自己"；三层一路写到根', () {
      expect(index.fullName('root'), 'root');
      expect(index.fullName('a'), 'root · a');
      expect(index.fullName('a1'), 'root · a · a1');
      expect(index.fullName('b'), 'root · b');
    });

    test('分隔符可换（界面上要的是「分类名 · 项目名」那种读法）', () {
      expect(index.fullName('a1', separator: '/'), 'root/a/a1');
    });

    test('未知 id 给空串、悬挂父引用只丢了那一段前缀 —— 都不抛', () {
      expect(index.fullName('从来没有过这个 id'), '');
      // `gone` 的父不在批内 → 构造函数把它规范成根，所以它的全名就是自己
      expect(index.fullName('gone'), 'gone');
    });
  });
}
