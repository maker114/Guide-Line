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
import '../theme/shape_tokens.dart';

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
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        // 多要一条：只按 `hits.length` 判断截断会永远看到"正好 100 条"，
        // 分不出"刚好 100 条"与"还有更多"（Q20）。
        final hits = widget.app.ws.search(_query, limit: searchHitLimit + 1);
        final truncated = hits.length > searchHitLimit;
        final shown = truncated ? hits.sublist(0, searchHitLimit) : hits;
        final hasQuery = _query.trim().isNotEmpty;
        return Scaffold(
          appBar: AppBar(title: const Text('搜索')),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 搜索框做成**页面上一个明显的框**（实机反馈）：
              // 原来是标题栏里一个没有边框的输入框，看着像一行说明文字，
              // 第一眼根本认不出"这里能打字"。
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜项目 / 事件 / 任务 / 灵感',
                    // 能点的用胶囊（《界面规范》§4）
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(
                        Radius.circular(AppShapes.pillRadius),
                      ),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: hasQuery
                        ? IconButton(
                            tooltip: '清空',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _controller.clear();
                              setState(() => _query = '');
                            },
                          )
                        : null,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              if (hasQuery)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Text(
                    // 触到上限时必须如实说（Q20 / 《界面规范》§7）：只写「命中 100 条」，
                    // 用户会以为一共就这么多 —— 而"前 100 条"只是截断之后剩下的那一段。
                    shown.isEmpty
                        ? '没有匹配的结果'
                        : truncated
                            ? '命中 $searchHitLimit 条 · 只显示前 $searchHitLimit 条（还有更多）'
                            : '命中 ${shown.length} 条',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              Expanded(
                child: !hasQuery
                    ? const EmptyState(
                        icon: Icons.search,
                        title: '输入关键词开始搜索',
                        hint: '搜索范围：未归档的项目 / 事件 / 任务，以及待处理的灵感',
                      )
                    : shown.isEmpty
                        ? const EmptyState(
                            icon: Icons.search_off,
                            title: '没有匹配的结果',
                            hint: '换个词试试；已归档与已丢弃的去了归档区，不在这儿露面',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.only(bottom: 24),
                            itemCount: shown.length,
                            separatorBuilder: (_, _) => const Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                            ),
                            itemBuilder: (context, index) => _HitTile(
                              app: widget.app,
                              hit: shown[index],
                            ),
                          ),
              ),
            ],
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
    // 字段名与界面同步（Q4）：「目的」→「有什么问题 / 思路」，
    // 与项目详情页那个字段卡、AI 提示词里用的词一模一样。
    const labels = <String, String>{
      'title': '标题',
      'purpose': '有什么问题 / 思路',
      'implementation': '实现',
      'name': '名称',
      'text': '内容',
    };
    return labels[field] ?? field;
  }
}
