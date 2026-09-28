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
import '../common/status_selector.dart';
import '../theme/shape_tokens.dart';

/// 归档区（ADR-052）。
///
/// **所有「从主视图消失」的东西必须有唯一去处。** 归档区不是新实体，
/// 而是由 `archived` / `status` / `deleted` 推导出来的视图聚合，分**三档**
/// （2026-09-27 合并：原先把灵感拆成「已丢弃」「已合并」「被隐藏」三档，
/// 三档常常各是 0 条却各占一个横向页签，手机上得横向滚才看得全）：
///
/// ```
/// 已归档        项目 / 事件 / 任务（archived，只列级联根）
/// 已处理的灵感   被隐藏 + 已丢弃 + 已合并（逐条一个来源小胶囊）
/// 回收站        deleted（只列级联根），每条保留 30 天
/// ```
///
/// **灵感删除不进这里**：它是唯一不进回收站的实体（《定义与边界》§8），
/// 删除只留一条 30 天后骨架化的墓碑。
///
/// 每个分区都能**反向找回**；只有「彻底删除」是不可逆的，所以它必须二次确认。
///
/// 三档之间的切换用与「未完成 / 已完成 / 已搁置」**同一枚胶囊分段控件**
/// （2026-09-28 实机反馈：改成和其他界面一样的滑块），不再是下划线页签。
enum ArchiveSection {
  archived('已归档'),
  processed('已处理的灵感'),
  trash('回收站');

  const ArchiveSection(this.label);

  final String label;
}

class ArchivePage extends StatefulWidget {
  const ArchivePage({super.key, required this.app});

  final AppController app;

  @override
  State<ArchivePage> createState() => _ArchivePageState();
}

class _ArchivePageState extends State<ArchivePage> {
  ArchiveSection _section = ArchiveSection.archived;

  AppController get app => widget.app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final zone = app.ws.archiveZone;
        final processed = _ProcessedInspirations.of(zone);
        return Scaffold(
          appBar: AppBar(title: const Text('归档区')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 档名就是档名，**不往标签里塞数字**（实机反馈：除了文字描述之外
              // 别再加负担）；条数由每个分区自己的列表与空态去讲。
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: StatusPillSelector<ArchiveSection>(
                  values: ArchiveSection.values,
                  selected: _section,
                  labelOf: (each) => each.label,
                  onSelected: (value) => setState(() => _section = value),
                ),
              ),
              Expanded(
                child: switch (_section) {
                  ArchiveSection.archived =>
                    _ArchivedPane(app: app, items: zone.archivedRoots),
                  ArchiveSection.processed =>
                    _ProcessedInspirationsPane(app: app, items: processed.items),
                  ArchiveSection.trash =>
                    _TrashPane(app: app, items: zone.trashRoots),
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 「已处理的灵感」这一档里**每一条是从哪来的**。
enum ProcessedSource {
  /// 因所属项目被归档而看不见的**待处理**灵感（原文一个字没动、也没被处理过）
  hidden('被隐藏'),

  /// 被丢弃的（恢复就是放回待处理）
  discarded('已丢弃'),

  /// 已被合进项目的（恢复只放回灵感箱，项目里的内容不退回）
  merged('已合并');

  const ProcessedSource(this.label);

  /// 逐条打在灵感行上的小胶囊文案。
  final String label;
}

/// 「已处理的灵感」这一档的取数：三路合流、各带来源标记、按更新时间倒序。
///
/// 单独抽一个值对象，是为了让「页签上的数字」与「列表里的条数」出自
/// **同一处** —— 界面上写 7 条、点进去只有 5 条，是实机反馈里被点过名的那类问题。
class _ProcessedInspirations {
  const _ProcessedInspirations(this.items);

  final List<({Entity entity, ProcessedSource source})> items;

  int get total => items.length;

  static _ProcessedInspirations of(ArchiveZone zone) {
    final out = <({Entity entity, ProcessedSource source})>[
      for (final item in zone.hiddenInspirations)
        (entity: item, source: ProcessedSource.hidden),
      for (final item in zone.discardedInspirations)
        (entity: item, source: ProcessedSource.discarded),
      for (final item in zone.mergedInspirations)
        (entity: item, source: ProcessedSource.merged),
    ]..sort((a, b) => b.entity.updatedAt.compareTo(a.entity.updatedAt));
    return _ProcessedInspirations(out);
  }
}

/// 灵感行上的**来源小胶囊**（《界面规范》§1：标签一律用胶囊）。
///
/// 三档合一之后，用户更需要一眼分清"这条是被我丢了、还是合进项目了、
/// 还是仅仅因为项目归档而看不见" —— 这三件事的**出路完全不同**
/// （放回待处理 / 项目内容不退回 / 取消归档那个项目）。
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});

  final ProcessedSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 三档各取一个**真正不同的家族**，颜色一律从 `colorScheme` 取、不硬编码。
    //
    // 为什么不是三个 `*Container`（2026-09-28 实测量出来的约束）：这套配色由单一
    // seed 推导，`secondaryContainer` / `tertiaryContainer` / `primaryContainer`
    // **就是同一个值**（两两 RGB 距离恒为 0）—— 拿它们当三档等于没分。
    // 真正互相分得开的是三个家族：
    //   · **已合并** → `primaryContainer`（已经落进项目里，最实）；
    //   · **已丢弃** → `errorContainer`（被扔掉的）；
    //   · **被隐藏** → **纯底 + 细描边**：它最轻（只是被遮住、没被处理过），
    //     而"淡灰底"那一带在本调色板里与 error 档天然只差 36（浅色主题下），
    //     所以不跟它们比底色，改用**形状**区分 —— 描边胶囊 vs 实底胶囊。
    // 距离由 `test/ui/source_chip_tone_test.dart` 在五套主题 × 深浅两套下量着。
    final (Color background, Color foreground) = switch (source) {
      ProcessedSource.hidden => (
          scheme.surface,
          scheme.onSurfaceVariant,
        ),
      ProcessedSource.discarded => (
          scheme.errorContainer,
          scheme.onErrorContainer,
        ),
      ProcessedSource.merged => (
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppShapes.chipRadius),
        // 只有"被隐藏"这一档描边：它没有实底，靠轮廓才站得住
        border: source == ProcessedSource.hidden
            ? Border.all(color: scheme.outlineVariant)
            : null,
      ),
      child: Text(
        source.label,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
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

class _ProcessedInspirationsPane extends StatelessWidget {
  const _ProcessedInspirationsPane({required this.app, required this.items});

  final AppController app;

  /// 三路合流之后的条目（已按更新时间倒序）。
  final List<({Entity entity, ProcessedSource source})> items;

  @override
  Widget build(BuildContext context) {
    // 分区说明必须与动作名**说同一件事**（Q9）：三档合一之后，这里要把
    // 「三件事的出路不一样」一次讲清 —— 尤其是"合并过的那条，项目里的内容
    // 不会退回来"，那是涉及数据会不会回来的一句，必须留。
    const note = '「恢复为待处理」只把灵感放回灵感箱；'
        '已合并的那些，写进项目里的内容不会退回。'
        '「被隐藏」的那些，取消归档对应项目即可自动回到灵感列表。';
    if (items.isEmpty) {
      return _Pane(
        note: note,
        child: _empty('没有已处理的灵感', '丢弃 / 合并灵感、或归档一个项目之后，相关的灵感会出现在这里'),
      );
    }
    return _Pane(
      note: note,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
        itemBuilder: (context, index) {
          final entry = items[index];
          // 归档区把灵感与树形实体放在同一个列表里返回，这里按分区语义收回具体类型
          final inspiration = entry.entity as Inspiration;
          final merged = entry.source == ProcessedSource.merged;
          // 「被隐藏」的那条**没有动作可做**：它没被处理过，只是所在项目归档了 ——
          // 出路是去把那个项目取消归档，不是"恢复为待处理"。
          final actionable = entry.source != ProcessedSource.hidden;
          return ListTile(
            isThreeLine: true,
            leading: const Icon(Icons.lightbulb_outline),
            title: Text(inspiration.text, maxLines: 3, overflow: TextOverflow.ellipsis),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: <Widget>[
                  _SourceChip(source: entry.source),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_projectName(inspiration)} · ${relativeTime(inspiration.updatedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
            trailing: actionable
                ? PopupMenuButton<String>(
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
                          final error =
                              app.run(() => app.ws.restoreInspiration(inspiration.id));
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
                  )
                : null,
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
