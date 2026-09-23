import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/entity.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/models/task.dart';
import '../common/dialogs.dart';
import '../common/empty_state.dart';
import '../common/format.dart';
import '../common/labels.dart';

/// 归档区（设计文档 4.10 / ADR-052）。
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
  const _Pane({required this.note, required this.child});

  final String note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Text(note, style: theme.textTheme.bodySmall),
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
        note: '归档是「暂时不做但不想删」，随时可以取消归档。',
        child: _empty('没有已归档的内容', '归档项目 / 事件 / 任务后会出现在这里'),
      );
    }
    return _Pane(
      note: '只列**归档根**（父节点也归档的不重复列出）；取消归档会沿树级联恢复。',
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
    final note = merged
        ? '合并是「吸收」：原文留在这里，正文归项目。撤销合并只把灵感恢复为待处理，不回滚项目正文。'
        : '丢弃是「想过但不要了」。可以恢复为待处理，也可以彻底删除。';
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
                    showToast(context, '已撤销合并，灵感回到待处理');
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
                  child: Text(merged ? '撤销合并' : '恢复为待处理'),
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
        note: '删除是「置墓碑」，数据还在文件里，随时可以恢复。',
        child: _empty('回收站是空的', '删除的项目 / 事件 / 任务会先落到这里'),
      );
    }
    return _Pane(
      note: '只列**级联根**；恢复会连同被一起删掉的下级一起回来。「彻底删除」不可撤销。',
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
    final error = app.run(() => app.ws.restoreFromTrash(_docOf(entity), entity.id));
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已恢复：${entityTitle(entity)}');
  }
}

// ---------------------------------------------------------------- 被隐藏

class _HiddenPane extends StatelessWidget {
  const _HiddenPane({required this.items});

  final List<Entity> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _Pane(
        note: '项目归档后，挂在它下面的未处理灵感会暂时隐藏。',
        child: _empty('没有被隐藏的灵感', '取消归档对应项目即可让它们回到灵感列表'),
      );
    }
    return _Pane(
      note: '这些灵感的所属项目已归档，因此不占用灵感列表。取消归档项目即可让它们回来。',
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
        ? '「${entityTitle(entity)}」的内容会被清空，只留一条墓碑记录。此操作**不可撤销**。'
        : '「${entityTitle(entity)}」及其下 $extra 条关联记录的内容会被清空，只留墓碑。此操作**不可撤销**。',
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
