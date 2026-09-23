import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/entity.dart';
import '../../core/models/enums.dart';
import '../../core/models/event.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/models/task.dart';
import '../shared/widgets.dart';

/// 归档区（设计文档 4.10 / ADR-052）：**所有"从主视图消失"的东西的唯一去处**。
///
/// 分区：已归档 / 已丢弃 / 已合并 / 回收站 / 本地草稿。
/// 只有在这里才能执行**彻底删除**（二次确认 + 墓碑骨架化）。
class ArchiveZonePage extends StatelessWidget {
  const ArchiveZonePage({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final zone = ws.archiveZone;
    final drafts = app.store.listConflictDrafts();

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        _Section(
          title: '已归档（${zone.archivedRoots.length}）',
          emptyHint: '归档的项目 / 事件 / 任务会出现在这里；取消归档会连同子节点一起恢复',
          children: <Widget>[
            for (final entity in zone.archivedRoots)
              _EntityRow(
                app: app,
                entity: entity,
                subtitle: '归档于 ${formatTimestamp(entity.updatedAt)}',
                actions: <Widget>[
                  TextButton(
                    onPressed: () {
                      final error = _unarchive(app, entity);
                      if (error != null) {
                        showNotice(context, error, error: true);
                      } else {
                        showNotice(context, '已取消归档（含子节点）');
                      }
                    },
                    child: const Text('取消归档'),
                  ),
                  _purgeButton(context, app, entity),
                ],
              ),
          ],
        ),
        _Section(
          title: '已丢弃（${zone.discardedInspirations.length}）',
          emptyHint: '主动放弃的灵感会留在这里，可以恢复',
          children: <Widget>[
            for (final entity in zone.discardedInspirations)
              _EntityRow(
                app: app,
                entity: entity,
                actions: <Widget>[
                  TextButton(
                    onPressed: () {
                      app.run(() => ws.restoreInspiration(entity.id));
                      showNotice(context, '已恢复为待处理');
                    },
                    child: const Text('恢复'),
                  ),
                  _purgeButton(context, app, entity),
                ],
              ),
          ],
        ),
        _Section(
          title: '已合并（${zone.mergedInspirations.length}）',
          emptyHint: '被项目吸收的灵感留在这里，可以撤销合并',
          children: <Widget>[
            for (final entity in zone.mergedInspirations)
              _EntityRow(
                app: app,
                entity: entity,
                subtitle: _mergedSubtitle(app, entity),
                actions: <Widget>[
                  TextButton(
                    onPressed: () {
                      final error = app.run(() => ws.undoMerge(entity.id));
                      if (error != null) {
                        showNotice(context, error, error: true);
                      } else {
                        showNotice(context, '已撤销合并（项目正文不会回滚）');
                      }
                    },
                    child: const Text('撤销合并'),
                  ),
                  _purgeButton(context, app, entity),
                ],
              ),
          ],
        ),
        _Section(
          title: '回收站（${zone.trashRoots.length}）',
          emptyHint: '删除的内容会留在这里，恢复时会连同子节点一起回来',
          children: <Widget>[
            for (final entity in zone.trashRoots)
              _EntityRow(
                app: app,
                entity: entity,
                subtitle: '删除于 ${formatTimestamp(entity.updatedAt)}',
                actions: <Widget>[
                  TextButton(
                    onPressed: () {
                      final doc = _docOf(entity);
                      final restored = ws.restoreFromTrash(doc, entity.id);
                      showNotice(context, '已恢复 ${restored.length} 条记录');
                    },
                    child: const Text('恢复'),
                  ),
                  _purgeButton(context, app, entity),
                ],
              ),
          ],
        ),
        _Section(
          title: '本地草稿（${drafts.length}）',
          emptyHint: '冲突与导入时被保留下来的本地文件（不参与同步）',
          children: <Widget>[
            for (final file in drafts)
              ListTile(
                dense: true,
                leading: const Icon(Icons.description_outlined),
                title: Text(file.uri.pathSegments.last),
                subtitle: Text(file.path),
                trailing: IconButton(
                  tooltip: '删除草稿',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => file.deleteSync(),
                ),
              ),
          ],
        ),
      ],
    );
  }

  static String? _unarchive(AppController app, Entity entity) {
    final ws = app.ws;
    if (entity is Project) return app.run(() => ws.setProjectArchived(entity.id, false));
    if (entity is Event) return app.run(() => ws.setEventArchived(entity.id, false));
    if (entity is Task) return app.run(() => ws.setTaskArchived(entity.id, false));
    return '该类型不支持取消归档';
  }

  static String _mergedSubtitle(AppController app, Entity entity) {
    if (entity is! Inspiration) return '';
    final target = entity.mergedInto == null ? null : app.ws.findProject(entity.mergedInto!);
    return '已并入「${target?.title ?? '（目标项目已删除）'}」 · ${formatTimestamp(entity.mergedAt)}';
  }

  static DocName _docOf(Entity entity) {
    if (entity is Project) return DocName.projects;
    if (entity is Event) return DocName.events;
    if (entity is Task) return DocName.tasks;
    return DocName.inspirations;
  }

  static Widget _purgeButton(BuildContext context, AppController app, Entity entity) {
    return TextButton(
      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
      onPressed: () async {
        final doc = _docOf(entity);
        final ids = app.ws.purgeIdsFor(doc, entity.id);
        final confirmed = await confirmAction(
          context,
          title: '彻底删除',
          message: '「${_titleOf(entity)}」'
              '${ids.length > 1 ? '及其 ${ids.length - 1} 条下级记录' : ''}将被永久抹除，**无法恢复**。\n\n'
              '只会保留一个"墓碑骨架"（防止离线设备把旧数据推回来），内容不再保留。',
          confirmLabel: '彻底删除',
          danger: true,
        );
        if (!confirmed) return;
        app.run(() => app.ws.purge(doc, ids));
        if (context.mounted) showNotice(context, '已彻底删除');
      },
      child: const Text('彻底删除'),
    );
  }

  static String _titleOf(Entity entity) {
    if (entity is Project) return entity.title;
    if (entity is Event) return entity.name;
    if (entity is Task) return entity.title;
    if (entity is Inspiration) return entity.text;
    return entity.id;
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.emptyHint, required this.children});

  final String title;
  final String emptyHint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionLabel(title),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              emptyHint,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        else
          ...children,
        const Divider(height: 24),
      ],
    );
  }
}

class _EntityRow extends StatelessWidget {
  const _EntityRow({
    required this.app,
    required this.entity,
    required this.actions,
    this.subtitle,
  });

  final AppController app;
  final Entity entity;
  final List<Widget> actions;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(_iconOf(entity), size: 18),
      title: Text(ArchiveZonePage._titleOf(entity)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
    );
  }

  static IconData _iconOf(Entity entity) {
    if (entity is Project) return Icons.account_tree_outlined;
    if (entity is Event) return Icons.timeline_outlined;
    if (entity is Task) return Icons.checklist_outlined;
    if (entity is Inspiration) return Icons.lightbulb_outline;
    return Icons.help_outline;
  }
}
