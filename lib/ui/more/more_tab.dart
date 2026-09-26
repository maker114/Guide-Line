import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/ai_config.dart';
import '../../platform/data_directory.dart';
import '../common/format.dart';
import '../common/section_header.dart';
import '../projects/ai_settings_page.dart';
import '../theme/app_theme.dart';
import 'all_tasks_page.dart';
import 'appearance_page.dart';
import 'archive_page.dart';
import 'backups_page.dart';
import 'export_page.dart';
import 'search_page.dart';
import 'upcoming_page.dart';

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
    // 「接下来的任务」：还开着的任务（未完成、未搁置、不在已搁置事件下），
    // 含没排期的 —— 与那个页面的列表同一口径
    final upcoming = ws.openTasks().length;
    final backups = app.backups;
    final searchable =
        app.projectCount + app.eventCount + app.taskCount + app.inspirationCount;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        const SectionHeader('浏览'),
        _MoreItem(
          icon: Icons.upcoming_outlined,
          title: '接下来的任务',
          subtitle: upcoming == 0 ? '现在没有待办' : '接下来 $upcoming 条待办（含没排期的）',
          page: UpcomingTasksPage(app: app),
        ),
        _MoreItem(
          icon: Icons.checklist_outlined,
          title: '全部任务',
          subtitle: '当前 ${app.taskCount} 条（含子任务）',
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
        const SectionHeader('外观'),
        _MoreItem(
          icon: Icons.palette_outlined,
          title: '主题与背景',
          subtitle: _appearanceSubtitle(),
          page: AppearancePage(app: app),
        ),
        const SectionHeader('AI'),
        _MoreItem(
          icon: Icons.auto_awesome_outlined,
          title: 'AI 整理',
          subtitle: _aiSubtitle(context),
          page: AiSettingsPage(app: app),
        ),
        const SectionHeader('数据安全'),
        _MoreItem(
          icon: Icons.history,
          title: '备份与恢复',
          subtitle: '${backups.length} 份可用备份（滚动保留 10 份 + 日快照 7 天）',
          page: BackupsPage(app: app),
        ),
        _MoreItem(
          icon: Icons.ios_share,
          title: '导出 / 导入',
          subtitle: _exportSubtitle(),
          danger: app.exportOverdue,
          page: ExportPage(app: app),
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
          subtitle: Text('${AppInfo.versionLabel}（Android 单机版）'),
        ),
      ],
    );
  }

  /// 导出入口的副标题：把"多久没导出"直接摆在列表上。
  String _exportSubtitle() {
    final last = app.lastExportedAt;
    if (last == null) return '还没有导出过 —— 数据只在这台手机里';
    final when = relativeTime(last);
    if (app.exportOverdue) {
      return '上次导出 $when，已超过 ${AppController.exportReminderDays} 天';
    }
    return '上次导出 $when · 导出为 .json.gz 后可分享出去';
  }

  /// 外观入口的副标题：一眼看出当前是哪套主题、有没有背景图。
  String _appearanceSubtitle() {
    final prefs = app.prefs;
    final themeName = prefs.themeId == followBackgroundThemeId
        ? '跟随背景图'
        : presetOf(prefs.themeId).name;
    final background = prefs.hasBackground ? ' · 有背景图' : '';
    return '$themeName$background';
  }

  /// AI 入口的副标题。
  ///
  /// `apiKey` 在安全存储里，只能异步读；用一个 `FutureBuilder` 局部处理，
  /// **不**把 Key 拉进控制器状态 —— 这个副标题只是装饰，
  /// 不该为了它让整页在启动时多一次异步依赖。
  ///
  /// 总开关关着时这一行**仍然留着**：它是回去把开关打开的唯一下口，
  /// 藏掉它就等于"关掉之后再也没法打开"。
  Widget _aiSubtitle(BuildContext context) {
    if (!app.aiEnabled) {
      return Text('已关闭 · 项目里不再显示 AI 整理入口', style: Theme.of(context).textTheme.bodySmall);
    }
    return FutureBuilder<AiConfig>(
      future: app.readAiConfig(),
      builder: (context, snapshot) {
        final config = snapshot.data;
        final String text;
        if (config == null) {
          text = '用于把实现清单整理成「实现计划」';
        } else if (config.isConfigured) {
          text = '已配置 · ${config.model}';
        } else {
          text = '未配置（${config.validate()}）';
        }
        return Text(text, style: Theme.of(context).textTheme.bodySmall);
      },
    );
  }
}

class _MoreItem extends StatelessWidget {
  const _MoreItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.page,
    this.danger = false,
  });

  final IconData icon;
  final String title;

  /// 静态文案；需要异步取值的入口（AI 配置）直接传一个组件进来。
  final Object subtitle;

  final Widget page;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dangerStyle = danger ? TextStyle(color: theme.colorScheme.error) : null;
    return ListTile(
      leading: Icon(icon, color: danger ? theme.colorScheme.error : null),
      title: Text(title),
      subtitle: switch (subtitle) {
        final Widget widget => widget,
        final String text => Text(text, style: dangerStyle),
        _ => const SizedBox.shrink(),
      },
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => page),
      ),
    );
  }
}
