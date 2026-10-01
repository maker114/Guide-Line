import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/ui/common/selection.dart';

/// 「全选」那一格的**跨页口径**。
///
/// 这段判断原来在四个页面里各写一遍（灵感页 / 全部任务 / 搜索 / 项目详情页的待处理灵感），
/// 四个 `_toggleSelectAll` 的**变异逻辑逐字相同**、只有"可见项"的来源不同。
/// 抽成纯函数之后，这一格的口径可以独立钉住 —— 不必为了验它去搭四个 widget。
///
/// 更有价值的是最后两条：它们记录的是**这一格为什么不能改成"集合包含"**，
/// 以及"全选只作用于当前可见项"这条口径在筛选之后意味着什么。
void main() {
  test('一个可见项都没有：全选之后仍是空（不可能"选中"不存在的东西）', () {
    expect(
      selectionAfterToggleAll(visibleIds: <String>{}, selectedIds: <String>{}),
      isEmpty,
    );
  });

  test('已经全选：再按一次是取消（清空）', () {
    expect(
      selectionAfterToggleAll(
        visibleIds: <String>{'a', 'b'},
        selectedIds: <String>{'a', 'b'},
      ),
      isEmpty,
    );
  });

  test('部分选中：全选键把可见项**全部**选中', () {
    expect(
      selectionAfterToggleAll(
        visibleIds: <String>{'a', 'b', 'c'},
        selectedIds: <String>{'a'},
      ),
      <String>{'a', 'b', 'c'},
    );
  });

  test('可见项比选中项多：全选键把可见项**全部**选中（不是增量追加）', () {
    // 场景：先前选中了 a，之后可见项变成 {b, c, d}（筛选或数据变了）。
    // 幽灵选中（a 已不可见）由各页在 build 里清掉；这里只回答"全选给什么"。
    // 若实现改成"把可见项 addAll 进现有选中"，结果会多出 a —— 与
    // "只作用于当前可见项"直接矛盾（动作条上写的就是这句话）。
    expect(
      selectionAfterToggleAll(
        visibleIds: <String>{'b', 'c', 'd'},
        selectedIds: <String>{'a'},
      ),
      <String>{'b', 'c', 'd'},
    );
    expect(
      selectionAfterToggleAll(
        visibleIds: <String>{'c', 'd'},
        selectedIds: <String>{'a', 'b', 'z'},
      ),
      <String>{'c', 'd'},
      reason: '选中 3 条、可见 2 条 → 不是"已全选"，照给全部可见项',
    );
  });

  test('判据是**条数相等**，不是集合包含 —— 幽灵选中会让"全选"变成"取消"', () {
    // ⚠️ 这一条记录的是**既有的、被四处共享的行为**，也是这一格最容易踩的空子：
    //   selected = {a, b}（其中 b 已经不在可见项里），visible = {c, d}。
    //   · 集合包含：{a,b} ⊄ {c,d} → 判"没全选" → 返回 {c,d}
    //   · 条数相等：2 == 2        → 判"**已全选**" → 返回**空**（取消全选）
    //   实际走的是后者。也就是说：**残留的幽灵选中会让第一次按"全选"变成取消**。
    //
    // 四个页面原来都用 `length ==`，所以这是共享口径、不是本项目新引入的偏差；
    // 各页在 build 里清幽灵选中，正是为了把这种残留压到最小。
    // 要改成"集合包含"得**四处一起改**，并且想清清理时序 —— 这条用例存在的意义
    // 就是让那次改动不能悄悄发生。
    expect(
      selectionAfterToggleAll(
        visibleIds: <String>{'c', 'd'},
        selectedIds: <String>{'a', 'b'},
      ),
      isEmpty,
      reason: '条数相等即判"已全选" —— 既有口径；改它要连幽灵选中的清理时序一起想',
    );
  });

  test('返回值是**新集合**，不回传调用方的那个（免得被就地改）', () {
    final visible = <String>{'a', 'b'};
    final next = selectionAfterToggleAll(
      visibleIds: visible,
      selectedIds: <String>{},
    );
    expect(next, <String>{'a', 'b'});
    expect(identical(next, visible), isFalse, reason: '必须是拷贝');
    next.add('c');
    expect(visible, <String>{'a', 'b'}, reason: '改返回值不该动到传入的可见项集合');
  });
}
