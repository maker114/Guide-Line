import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/entity.dart';
import '../../core/models/event.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/models/task.dart';
import '../../features/workspace.dart';
import '../shared/widgets.dart';

/// 全局搜索（Q42）。
///
/// 口径与归档区一致：**只搜未归档、未删除**；灵感只搜 `pending`
/// （`merged` / `discarded` 要去归档区找）。
class SearchView extends StatefulWidget {
  const SearchView({
    super.key,
    required this.app,
    required this.onOpenProject,
    required this.onOpenEvent,
  });

  final AppController app;
  final ValueChanged<String> onOpenProject;
  final ValueChanged<String> onOpenEvent;

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 每次重建都按当前关键词现算：数据在别处发生变化时结果不会变陈旧
    final hits = widget.app.ws.search(_query.text);
    final grouped = <String, List<SearchHit>>{
      '项目': <SearchHit>[],
      '事件': <SearchHit>[],
      '任务': <SearchHit>[],
      '灵感': <SearchHit>[],
    };
    for (final hit in hits) {
      if (hit.entity is Project) {
        grouped['项目']!.add(hit);
      } else if (hit.entity is Event) {
        grouped['事件']!.add(hit);
      } else if (hit.entity is Task) {
        grouped['任务']!.add(hit);
      } else if (hit.entity is Inspiration) {
        grouped['灵感']!.add(hit);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: TextField(
            controller: _query,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: '搜索项目 / 事件 / 任务 / 灵感（不含已归档与已删除）',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _query.clear();
                        setState(() {});
                      },
                    ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _query.text.trim().isEmpty
              ? const EmptyState(
                  icon: Icons.search,
                  title: '输入关键词开始搜索',
                  hint: '会同时搜项目名/目的/实现、事件名、任务名与灵感正文',
                )
              : hits.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off,
                      title: '没有匹配结果',
                      hint: '已归档与已删除的内容不参与搜索（可在归档区查看）',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: <Widget>[
                        for (final entry in grouped.entries)
                          if (entry.value.isNotEmpty) ...<Widget>[
                            SectionLabel('${entry.key}（${entry.value.length}）'),
                            for (final hit in entry.value)
                              _HitTile(
                                app: widget.app,
                                hit: hit,
                                onOpenProject: widget.onOpenProject,
                                onOpenEvent: widget.onOpenEvent,
                              ),
                          ],
                      ],
                    ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Text(
            _query.text.trim().isEmpty ? '' : '命中 ${hits.length} 条'
                '${hits.length >= 100 ? '（已截断到 100 条）' : ''}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({
    required this.app,
    required this.hit,
    required this.onOpenProject,
    required this.onOpenEvent,
  });

  final AppController app;
  final SearchHit hit;
  final ValueChanged<String> onOpenProject;
  final ValueChanged<String> onOpenEvent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entity = hit.entity;
    String? subtitle;
    String? trailingLabel;

    if (entity is Project) {
      subtitle = _excerpt(
        hit.matchedField == 'purpose'
            ? entity.purpose
            : hit.matchedField == 'implementation'
                ? entity.implementation
                : entity.purpose,
      );
      trailingLabel = entity.date;
    } else if (entity is Task) {
      final event = app.ws.findEvent(entity.eventId);
      subtitle = '${event?.name ?? '（事件已删除）'} · ${entity.dueAt ?? '无到期日'}';
      trailingLabel = NodeStatusChip.labelOf(entity.status);
    } else if (entity is Inspiration) {
      subtitle = entity.projectId == null
          ? '未分配'
          : '属于「${app.ws.findProject(entity.projectId!)?.title ?? '（项目已删除）'}」';
      trailingLabel = formatTimestamp(entity.createdAt);
    } else if (entity is Event) {
      final mainLine = app.ws.mainLineOf(entity.id);
      subtitle = '${mainLine.length} 个主线任务';
      trailingLabel = NodeStatusChip.labelOf(entity.status);
    }

    return ListTile(
      dense: true,
      leading: Icon(_iconOf(entity), size: 18, color: theme.colorScheme.outline),
      title: Text(hit.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
      trailing: trailingLabel == null
          ? null
          : Text(trailingLabel, style: theme.textTheme.labelSmall),
      onTap: () {
        if (entity is Project) {
          onOpenProject(entity.id);
        } else if (entity is Event) {
          onOpenEvent(entity.id);
        } else if (entity is Task) {
          onOpenEvent(entity.eventId);
        } else if (entity is Inspiration && entity.projectId != null) {
          onOpenProject(entity.projectId!);
        } else {
          showNotice(context, '该结果没有可打开的归属视图');
        }
      },
    );
  }

  static String _excerpt(String text) {
    final flat = text.replaceAll('\n', ' ').trim();
    if (flat.length <= 80) return flat;
    return '${flat.substring(0, 80)}…';
  }

  static IconData _iconOf(Entity entity) {
    if (entity is Project) return Icons.account_tree_outlined;
    if (entity is Event) return Icons.timeline_outlined;
    if (entity is Task) return Icons.checklist_outlined;
    return Icons.lightbulb_outline;
  }
}
