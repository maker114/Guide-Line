import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/project.dart';
import 'color_picker.dart';
import 'dialogs.dart';

/// [pickProject] 中「不选 / 移到根」这一项的值。
///
/// 项目 id 是 UUID，不可能等于这个字面量，所以用哨兵值区分
/// 「用户选了『不选』」和「用户取消了选择」（后者返回 `null`）。
const String pickNone = '__none__';

/// 分类不能当灵感的落点时给的那句提示（Q2：**灵感只落在目标上**）。
/// 也用在同一份规则的另一道闸门上（`MergeEditorPage` / `applyMergeResult`）。
const String categoryNotForInspiration = '分类不装灵感，请选一个目标或先建一个目标';

/// 项目选择器：底部弹出的树形列表（带缩进）。
///
/// 只列**未归档**的项目。移动场景用 [excludeSubtreeOf] 排除自身及其后代，
/// 避免出现「把自己移到自己下面」这种必然被业务规则拒绝的选项。
///
/// [requireTarget]（默认 `true`）用来区分两类调用：
///   · **灵感侧**（分配 / 合并）：落点只能是**目标** —— 分类只回答"归哪一类"，
///     不装灵感，选中时给一句 [categoryNotForInspiration] 而不是静默生效；
///   · **移动侧**（`moveProjectAction`）：把项目移进一个分类正是"建分类"的做法，
///     所以那边传 `false`，分类照常可选。
Future<String?> pickProject(
  BuildContext context,
  AppController app, {
  required String title,
  bool allowNone = false,
  String noneLabel = '不选，或移到根层',
  String? excludeSubtreeOf,
  bool requireTarget = true,
}) {
  final tree = app.ws.projectTree;
  final excluded = <String>{};
  if (excludeSubtreeOf != null) {
    for (final node in tree.subtreeOf(excludeSubtreeOf)) {
      excluded.add(node.id);
    }
  }

  final flat = <MapEntry<Project, int>>[];
  void walk(String? parentId, int depth) {
    for (final project in tree.childrenOf(parentId).whereType<Project>()) {
      if (project.archived || excluded.contains(project.id)) continue;
      flat.add(MapEntry(project, depth));
      walk(project.id, depth + 1);
    }
  }

  walk(null, 0);

  /// 灵感侧：分类不是合法落点（移动侧 `requireTarget = false`，一律放行）。
  bool blocked(Project project) => requireTarget && app.ws.isProjectCategory(project.id);

  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
          ),
          if (requireTarget)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '灵感只能并进「目标」；分类只回答"归哪一类"。',
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
            ),
          if (flat.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text('没有可选的项目'),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  if (allowNone)
                    ListTile(
                      leading: const Icon(Icons.vertical_align_top),
                      title: Text(noneLabel),
                      onTap: () => Navigator.of(sheetContext).pop(pickNone),
                    ),
                  for (final entry in flat)
                    ListTile(
                      contentPadding: EdgeInsets.only(left: 16.0 + entry.value * 20, right: 16),
                      // 标识色也带到这里：分配灵感时能按颜色认项目，
                      // 与项目树上是同一套视觉线索
                      leading: ProjectMarker(color: entry.key.color),
                      title: Text(entry.key.title),
                      // 分类明说"这里不装灵感"，一眼能看出该往下选目标。
                      // **刻意不置 `enabled: false`**：禁用的行点不动，也就给不出
                      // "为什么不能选"的解释 —— 这里要让点它的人收到一句提示。
                      subtitle: blocked(entry.key) ? const Text('分类，这里不装灵感') : null,
                      onTap: () {
                        if (blocked(entry.key)) {
                          showToast(sheetContext, categoryNotForInspiration, error: true);
                          return;
                        }
                        Navigator.of(sheetContext).pop(entry.key.id);
                      },
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
