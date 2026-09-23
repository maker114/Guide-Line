import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/project.dart';

/// [pickProject] 中「不选 / 移到根」这一项的值。
///
/// 项目 id 是 UUID，不可能等于这个字面量，所以用哨兵值区分
/// 「用户选了『不选』」和「用户取消了选择」（后者返回 `null`）。
const String pickNone = '__none__';

/// 项目选择器：底部弹出的树形列表（带缩进）。
///
/// 只列**未归档**的项目。移动场景用 [excludeSubtreeOf] 排除自身及其后代，
/// 避免出现「把自己移到自己下面」这种必然被业务规则拒绝的选项。
Future<String?> pickProject(
  BuildContext context,
  AppController app, {
  required String title,
  bool allowNone = false,
  String noneLabel = '（不选 / 移到根）',
  String? excludeSubtreeOf,
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
                      leading: const Icon(Icons.folder_outlined, size: 18),
                      title: Text(entry.key.title),
                      onTap: () => Navigator.of(sheetContext).pop(entry.key.id),
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
