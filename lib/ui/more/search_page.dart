import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/task.dart';
import '../../features/workspace.dart';
import '../common/empty_state.dart';
import '../common/labels.dart';
import '../events/event_detail_page.dart';
import '../projects/project_detail_page.dart';

/// 全局搜索（设计文档 Q42）：**只搜未归档、未删除；灵感只搜待处理的**。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.app});

  final AppController app;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final hits = widget.app.ws.search(_query);
        return Scaffold(
          appBar: AppBar(
            title: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: '项目 / 事件 / 任务 / 灵感',
                border: InputBorder.none,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            actions: <Widget>[
              if (_query.isNotEmpty)
                IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _controller.clear();
                    setState(() => _query = '');
                  },
                ),
            ],
          ),
          body: _query.trim().isEmpty
              ? const EmptyState(
                  icon: Icons.search,
                  title: '输入关键词开始搜索',
                  hint: '搜索范围：未归档的项目 / 事件 / 任务，以及待处理的灵感',
                )
              : hits.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off,
                      title: '没有匹配的结果',
                      hint: '换个词试试；已归档与已丢弃的内容不参与搜索',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: hits.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 16, endIndent: 16),
                      itemBuilder: (context, index) => _HitTile(
                        app: widget.app,
                        hit: hits[index],
                      ),
                    ),
        );
      },
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.app, required this.hit});

  final AppController app;
  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entity = hit.entity;
    return ListTile(
      leading: Icon(entityTypeIcon(entity)),
      title: Text(hit.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${entityTypeLabel(entity)} · 命中「${_fieldLabel(hit.matchedField)}」',
        style: theme.textTheme.labelSmall,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(context),
    );
  }

  Future<void> _open(BuildContext context) async {
    final entity = hit.entity;
    switch (hit.doc) {
      case DocName.projects:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ProjectDetailPage(app: app, projectId: entity.id),
          ),
        );
        break;
      case DocName.events:
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => EventDetailPage(app: app, eventId: entity.id),
          ),
        );
        break;
      case DocName.tasks:
        final task = entity as Task;
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => EventDetailPage(app: app, eventId: task.eventId),
          ),
        );
        break;
      case DocName.inspirations:
        final inspiration = entity as Inspiration;
        if (!context.mounted) return;
        await showModalBottomSheet<void>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('灵感原文', style: Theme.of(sheetContext).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Text(inspiration.text),
                  const SizedBox(height: 12),
                  Text(
                    '去「灵感」页可以把它分配 / 合并 / 丢弃',
                    style: Theme.of(sheetContext).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        );
        break;
    }
  }

  static String _fieldLabel(String field) {
    const labels = <String, String>{
      'title': '标题',
      'purpose': '目的',
      'implementation': '实现',
      'name': '名称',
      'text': '内容',
    };
    return labels[field] ?? field;
  }
}
