import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/entity.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/models/task.dart';
import '../../core/rules/archive_zone.dart';
import '../common/dialogs.dart';
import '../common/empty_state.dart';
import '../common/format.dart';
import '../common/labels.dart';

/// 归档区（ADR-052）。
///
/// **所有「从主视图消失」的东西必须有唯一去处。** 归档区不是新实体，
/// 而是由 `archived` / `status` / `deleted` 推导出来的视图聚合，分五个分区：
/// 已归档 / 已丢弃 / 已合并 / 回收站 / 因项目归档被隐藏。
///
/// 每个分区都能**反向找回**；只有「彻底删除」是不可逆的，所以它必须二次确认。
class ArchivePage extends StatelessWidget {
  const ArchivePage({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final zone = app.ws.archiveZone;
          return Scaffold(
            appBar: AppBar(
              title: const Text('归档区'),
              bottom: TabBar(
                isScrollable: true,
                tabs: <Widget>[
                  Tab(text: '已归档 ${zone.archivedRoots.length}'),
                  Tab(text: '已丢弃 ${zone.discardedInspirations.length}'),
                  Tab(text: '已合并 ${zone.mergedInspirations.length}'),
                  Tab(text: '回收站 ${zone.trashRoots.length}'),
                  Tab(text: '被隐藏 ${zone.hiddenInspirations.length}'),
                ],
              ),
            ),
            body: TabBarView(
              children: <Widget>[
                _ArchivedPane(app: app, items: zone.archivedRoots),
                _InspirationPane(
                  app: app,
                  items: zone.discardedInspirations,
                  merged: false,
                ),
                _InspirationPane(
                  app: app,
                  items: zone.mergedInspirations,
                  merged: true,
                ),
                _TrashPane(app: app, items: zone.trashRoots),
                _HiddenPane(items: zone.hiddenInspirations),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- 分区外壳

class _Pane extends StatelessWidget {
  const _Pane({this.note, required this.child});

  /// 分区说明。**没话可说就传 null**（顶上那条底纹也不画）——
  /// 说明性文字只留"数据去哪了 / 能不能撤回"这一类。
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final noteText = note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (noteText != null)
          Container(
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(noteText, style: theme.textTheme.bodySmall),
          ),
        Expanded(child: child),
      ],
    );
  }
}

Widget _empty(String title, String hint) =>
    EmptyState(icon: Icons.inventory_2_outlined, title: title, hint: hint);

String _updatedLabel(int millis) => '更新于 ${formatTimestamp(millis)}';

// ---------------------------------------------------------------- 已归档

class _ArchivedPane extends StatelessWidget {
  const _ArchivedPane({required this.app, required this.items});

  final AppController app;
  final List<Entity> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Pane(
        child: _empty('没有已归档的内容', '归档项目 / 事件 / 任务后会出现在这里'),
      );
    }
    return _Pane(
      // 「单独归档的子任务也能在这里找回」必须写出来（Q18）：任务线里现在
      // **不显示**已归档节点（显示与判定同一套取数），用户点进去会以为它没了。
      note: '单独归档的子任务也会列在这里 —— 任务线里不显示已归档的节点。',
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final entity = items[index];
          return ListTile(
            leading: Icon(entityTypeIcon(entity)),
            title: Text(entityTitle(entity), maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${entityTypeLabel(entity)} · ${_updatedLabel(entity.updatedAt)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            trailing: TextButton(
              onPressed: () => _unarchive(context, entity),
              child: const Text('取消归档'),
            ),
          );
        },
      ),
    );
  }

  void _unarchive(BuildContext context, Entity entity) {
    final ws = app.ws;
    final error = app.run(() {
      if (entity is Project) {
        ws.setProjectArchived(entity.id, false);
      } else if (entity is Event) {
        ws.setEventArchived(entity.id, false);
      } else if (entity is Task) {
        ws.setTaskArchived(entity.id, false);
      }
    });
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已取消归档：${entityTitle(entity)}');
  }
}

// ---------------------------------------------------------------- 灵感分区

class _InspirationPane extends StatelessWidget {
  const _InspirationPane({
    required this.app,
    required this.items,
    required this.merged,
  });

  final AppController app;
  final List<Entity> items;
  final bool merged;

  @override
  Widget build(BuildContext context) {
    // 分区说明与动作名必须**说同一件事**（Q9）：合并是"吸收"，恢复只把灵感
    // 放回待处理，项目里的那一行 / 那条清单**不退回** —— 这句话涉及数据会不会
    // 回来，必须留。
    final note = merged ? '「恢复为待处理」只把灵感放回灵感箱，项目里的内容不会退回。' : null;
    // 归档区把灵感与树形实体放在同一个列表里返回，这里按分区语义收回具体类型
    final list = items.whereType<Inspiration>().toList(growable: false);
    if (list.isEmpty) {
      return _Pane(
        note: note,
        child: _empty(merged ? '没有已合并的灵感' : '没有已丢弃的灵感', '处理灵感时会自动归档到这里'),
      );
    }
    return _Pane(
      note: note,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: list.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final inspiration = list[index];
          return ListTile(
            isThreeLine: true,
            leading: const Icon(Icons.lightbulb_outline),
            title: Text(inspiration.text, maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${_projectName(inspiration)} · ${relativeTime(inspiration.updatedAt)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) async {
                if (value == 'restore') {
                  if (merged) {
                    final error = app.run(() => app.ws.undoMerge(inspiration.id));
                    if (error != null) {
                      showToast(context, error, error: true);
                      return;
                    }
                    showToast(context, '已恢复为待处理，项目里的内容不会退回');
                  } else {
                    final error = app.run(() => app.ws.restoreInspiration(inspiration.id));
                    if (error != null) {
                      showToast(context, error, error: true);
                      return;
                    }
                    showToast(context, '已恢复为待处理');
                  }
                  return;
                }
                await _purge(context, app, inspiration);
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'restore',
                  // 名字里就把代价写出来（Q9）：这个动作**不回滚项目内容**，
                  // 只把灵感放回待处理。叫"撤销合并"会让人以为项目也一起退回去了。
                  child: Text(merged ? '恢复为待处理，项目内容不退回' : '恢复为待处理'),
                ),
                const PopupMenuItem<String>(value: 'purge', child: Text('彻底删除')),
              ],
            ),
          );
        },
      ),
    );
  }

  String _projectName(Inspiration inspiration) {
    final id = inspiration.projectId;
    if (id == null) return '未分配';
    final project = app.ws.findProject(id);
    return project == null ? '未分配' : '项目：${project.title}';
  }
}

// ---------------------------------------------------------------- 回收站

class _TrashPane extends StatelessWidget {
  const _TrashPane({required this.app, required this.items});

  final AppController app;
  final List<Entity> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Pane(
        child: _empty('回收站是空的', '删除的项目 / 事件 / 任务会先落到这里'),
      );
    }
    return _Pane(
      // 到期清理发生在**启动时**，不是"到点就删"，也不能让用户以为"彻底删除"
      // 还能退回 —— 这两句涉及数据会不会丢，必须留。
      note: '每条保留 $trashRetentionDays 天，到期的在下次启动时自动清除；'
          '「彻底删除」不可撤销。',
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final entity = items[index];
          return ListTile(
            leading: Icon(entityTypeIcon(entity)),
            title: Text(entityTitle(entity), maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${entityTypeLabel(entity)} · '
              '${describeTrashCountdown(trashDaysLeft(entity.updatedAt))}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            trailing: PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (value) async {
                if (value == 'restore') {
                  _restore(context, entity);
                  return;
                }
                await _purge(context, app, entity);
              },
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(value: 'restore', child: Text('恢复')),
                PopupMenuItem<String>(value: 'purge', child: Text('彻底删除')),
              ],
            ),
          );
        },
      ),
    );
  }

  void _restore(BuildContext context, Entity entity) {
    final doc = _docOf(entity);
    final restored = <String>{};
    final error = app.run(() {
      restored.addAll(app.ws.restoreFromTrash(doc, entity.id));
    });
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    // 删是级联删的，恢复也是级联恢复的 —— 提示必须说清**实际回来了多少**，
    // 只报一个名字，用户会以为下级还留在回收站里（Q12）。
    showToast(context, '已恢复：${_restoreScopeLabel(entity, doc, restored.length)}');
  }
}

/// 「已恢复」后面那半句：名字 + 实际范围与条数。
String _restoreScopeLabel(Entity entity, DocName doc, int total) {
  final name = entityTitle(entity);
  if (total <= 1) return name;
  if (doc == DocName.events) return '$name，含整条任务线共 $total 条';
  return '$name，含下级共 $total 条';
}

// ---------------------------------------------------------------- 被隐藏

class _HiddenPane extends StatelessWidget {
  const _HiddenPane({required this.items});

  final List<Entity> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Pane(
        child: _empty('没有被隐藏的灵感', '取消归档对应项目即可让它们回到灵感列表'),
      );
    }
    return _Pane(
      // 这些灵感"不见了"是算出来的，必须说清去哪找回来
      note: '所属项目已归档，所以它们不在灵感列表里；取消归档即可回来。',
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final inspiration = items[index];
          return ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: Text(entityTitle(inspiration), maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              relativeTime(inspiration.updatedAt),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- 公共动作

DocName _docOf(Entity entity) {
  if (entity is Project) return DocName.projects;
  if (entity is Event) return DocName.events;
  if (entity is Task) return DocName.tasks;
  return DocName.inspirations;
}

/// 彻底删除 = **墓碑骨架化**：只留 `id / deleted / purged_at`，其余字段清空。
Future<void> _purge(BuildContext context, AppController app, Entity entity) async {
  final doc = _docOf(entity);
  final ids = app.ws.purgeIdsFor(doc, entity.id);
  final extra = ids.length - 1;

  final ok = await confirmAction(
    context,
    title: '彻底删除',
    message: extra <= 0
        ? '「${entityTitle(entity)}」的内容会被清空，只留一条墓碑记录。此操作不可撤销。'
        : '「${entityTitle(entity)}」及其下 $extra 条关联记录的内容会被清空，只留墓碑。此操作不可撤销。',
    confirmLabel: '彻底删除',
    danger: true,
  );
  if (!ok || !context.mounted) return;

  final error = app.run(() => app.ws.purge(doc, ids));
  if (error != null) {
    showToast(context, error, error: true);
    return;
  }
  showToast(context, '已彻底删除 ${ids.length} 条记录');
}
