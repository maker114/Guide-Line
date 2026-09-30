import 'package:flutter/material.dart';

import '../../core/models/entity.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/models/task.dart';

/// 枚举 / 实体 → 中文文案。集中一处，避免同一状态在不同页面说法不一。

String nodeStatusLabel(NodeStatus status) {
  switch (status) {
    case NodeStatus.pending:
      return '未完成';
    case NodeStatus.done:
      return '已完成';
    case NodeStatus.ignored:
      return '已搁置';
  }
}

IconData nodeStatusIcon(NodeStatus status) {
  switch (status) {
    case NodeStatus.pending:
      return Icons.radio_button_unchecked;
    case NodeStatus.done:
      return Icons.check_circle;
    case NodeStatus.ignored:
      return Icons.remove_circle_outline;
  }
}

/// 未完成用描边色，终态用主色 —— 列表扫一眼就能看出哪些还欠着。
Color? nodeStatusColor(NodeStatus status, ColorScheme scheme) {
  switch (status) {
    case NodeStatus.pending:
      return scheme.outline;
    case NodeStatus.done:
      return scheme.primary;
    case NodeStatus.ignored:
      return scheme.outlineVariant;
  }
}

/// 实体类型名（归档区、搜索结果里给条目"贴标签"用）。
String entityTypeLabel(Entity entity) {
  if (entity is Project) return '项目';
  if (entity is Event) return '事件';
  if (entity is Task) return '任务';
  if (entity is Inspiration) return '灵感';
  return '记录';
}

IconData entityTypeIcon(Entity entity) {
  if (entity is Project) return Icons.folder_outlined;
  if (entity is Event) return Icons.timeline;
  if (entity is Task) return Icons.check_circle_outline;
  if (entity is Inspiration) return Icons.lightbulb_outline;
  return Icons.help_outline;
}

/// 数据集合名（版本差异面板等在标题里点出"哪一类变了"）。
String docNameLabel(DocName name) {
  switch (name) {
    case DocName.projects:
      return '项目';
    case DocName.inspirations:
      return '灵感';
    case DocName.events:
      return '事件';
    case DocName.tasks:
      return '任务';
  }
}

/// 实体的显示标题（各实体字段名不同：`title` / `name` / `text`）。
String entityTitle(Entity entity) {
  if (entity is Project) return entity.title;
  if (entity is Event) return entity.name;
  if (entity is Task) return entity.title;
  if (entity is Inspiration) return entity.text;
  return entity.id;
}
