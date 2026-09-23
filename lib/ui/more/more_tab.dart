import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../common/format.dart';
import '../common/section_header.dart';
import 'all_tasks_page.dart';
import 'archive_page.dart';
import 'backups_page.dart';
import 'due_page.dart';
import 'search_page.dart';

/// 更多 Tab：**浏览入口 + 数据安全 + 关于**。
///
/// 「灵感 / 项目 / 事件」三个 Tab 只放最高频的操作，
/// 聚合视图（到期、全部任务、搜索、归档区）与数据安全都收在这里。
class MoreTab extends StatelessWidget {
  const MoreTab({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final ws = app.ws;
    final due = ws.tasksDueOnOrBefore(dateOffset(0)).length;
    final backups = app.backups;
    final searchable =
        app.projectCount + app.eventCount + app.taskCount + app.inspirationCount;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        const SectionHeader('浏览'),
        _MoreItem(
          icon: Icons.event_available_outlined,
          title: '到期',
          subtitle: due == 0 ? '今天及之前没有到期的任务' : '今天及之前 $due 条待处理',
          page: DuePage(app: app),
        ),
        _MoreItem(
          icon: Icons.checklist_outlined,
          title: '全部任务',
          subtitle: '当前 ${app.taskCount} 条（含子任务与并列任务）',
          page: AllTasksPage(app: app),
        ),
        _MoreItem(
          icon: Icons.search,
          title: '搜索',
          subtitle: '$searchable 条内容可搜（不含已归档）',
          page: SearchPage(app: app),
        ),
        _MoreItem(
          icon: Icons.inventory_2_outlined,
          title: '归档区',
          subtitle: '已归档 / 已丢弃 / 已合并 / 回收站 共 ${app.archiveCount} 条',
          page: ArchivePage(app: app),
        ),
        const SectionHeader('数据安全'),
        _MoreItem(
          icon: Icons.history,
          title: '备份与恢复',
          subtitle: '${backups.length} 份可用备份（滚动保留 10 份 + 日快照 7 天）',
          page: BackupsPage(app: app),
        ),
        const ListTile(
          leading: Icon(Icons.ios_share),
          title: Text('导出 / 分享'),
          subtitle: Text('导出为 .json.gz 后通过系统分享发出'),
          enabled: false,
          trailing: Text('下一轮'),
        ),
        const SectionHeader('关于'),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('数据目录'),
          subtitle: Text(app.dataDirectory.path),
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('版本'),
          subtitle: Text('1.0.0+1（Android 单机版）'),
        ),
      ],
    );
  }
}

class _MoreItem extends StatelessWidget {
  const _MoreItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.page,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => page),
      ),
    );
  }
}
