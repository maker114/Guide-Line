import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/ai_config.dart';
import '../../core/rules/reminder_schedule.dart';
import '../../core/store/github_sync.dart';
import '../../core/store/ui_prefs.dart';
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
import 'github_backup_page.dart';
import 'reminder_page.dart';
import 'search_page.dart';
import 'upcoming_page.dart';

/// 更多 Tab：**浏览入口 + 数据安全 + 关于**。
///
/// 「灵感 / 项目 / 事件」三个 Tab 只放最高频的操作，
/// 聚合视图（到期、全部任务、搜索、归档区）与数据安全都收在这里。
class MoreTab extends StatefulWidget {
  const MoreTab({super.key, required this.app});

  final AppController app;

  @override
  State<MoreTab> createState() => _MoreTabState();
}

class _MoreTabState extends State<MoreTab> {
  late final AppController app = widget.app;

  /// AI 配置读起来要打平台通道（Keystore 是慢操作），所以**缓存这一份 Future**。
  ///
  /// 早先这里写在 `FutureBuilder(future: app.readAiConfig())` 里（Q-5）：
  /// 这一页被保活、而任何一次保存 / 勾选 / 改偏好都会通知重建，
  /// 于是每帧都重打一次平台通道，`FutureBuilder` 还会回落成 waiting、
  /// 把副标题闪回默认文案。
  late Future<AiConfig> _aiConfig = app.readAiConfig();

  /// 这份缓存对应的是哪一版配置 —— 设置页保存后 `aiConfigRevision` 会 +1，
  /// 下次重建时发现对不上就重读（不能只在 initState 读一次，那样改完配置副标题不会变）。
  late int _aiRevision = app.aiConfigRevision;

  @override
  Widget build(BuildContext context) {
    if (_aiRevision != app.aiConfigRevision) {
      _aiRevision = app.aiConfigRevision;
      _aiConfig = app.readAiConfig();
    }
    final ws = app.ws;
    // 「接下来的任务」：还开着的任务（未完成、未搁置、不在已搁置事件下），
    // 含没排期的 —— 与那个页面的列表同一口径
    final upcoming = ws.openTasks().length;
    final backups = app.backups;
    // 入口的副标题与页内数字**共用同一个计数**（Q20）：以前这里按"含已归档"加，
    // 点进去的页面按"排除已归档"算，两个数对不上。
    final searchable = app.searchableCount;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        const SectionHeader('浏览'),
        _MoreItem(
          icon: Icons.upcoming_outlined,
          title: '接下来的任务',
          subtitle: upcoming == 0 ? '现在没有待办' : '接下来 $upcoming 条待办，含没排期的',
          page: UpcomingTasksPage(app: app),
        ),
        _MoreItem(
          icon: Icons.checklist_outlined,
          title: '全部任务',
          subtitle: '当前 ${app.taskCount} 条，含子任务',
          page: AllTasksPage(app: app),
        ),
        _MoreItem(
          icon: Icons.search,
          title: '搜索',
          subtitle: '$searchable 条内容可搜，不含已归档',
          page: SearchPage(app: app),
        ),
        _MoreItem(
          icon: Icons.inventory_2_outlined,
          title: '归档区',
          subtitle: '已归档 / 已处理的灵感 / 回收站 共 ${app.archiveCount} 条',
          page: ArchivePage(app: app),
        ),
        const SectionHeader('外观'),
        _MoreItem(
          icon: Icons.palette_outlined,
          // 与页面标题一致（页面 AppBar 写的是「外观」）。原来这里写「主题与背景」，
          // 于是同一个地方在列表里和点进去之后叫两个名字 —— 2026-10-02 统一。
          // 选「外观」而不是「主题与背景」：这一页除了主题还有背景图、不透明度、
          // 模糊，叫「主题与背景」说不全。
          title: '外观',
          subtitle: _appearanceSubtitle(),
          page: AppearancePage(app: app),
        ),
        const SectionHeader('提醒'),
        _MoreItem(
          icon: Icons.alarm_outlined,
          title: '提醒',
          subtitle: _reminderSubtitle(),
          page: ReminderPage(app: app),
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
          subtitle: '${backups.length} 份可用备份，滚动留 10 份、日快照留 7 天',
          page: BackupsPage(app: app),
        ),
        _MoreItem(
          icon: Icons.ios_share,
          title: '导出 / 导入',
          subtitle: _exportSubtitle(),
          danger: app.exportOverdue,
          page: ExportPage(app: app),
        ),
        _MoreItem(
          icon: Icons.cloud_sync_outlined,
          title: 'GitHub 备份同步',
          subtitle: _gitHubSubtitle(context),
          page: GitHubBackupPage(app: app),
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
          subtitle: Text('${AppInfo.versionLabel} · Android 单机版'),
        ),
      ],
    );
  }

  /// 导出入口的副标题：把"多久没导出"直接摆在列表上。
  String _exportSubtitle() {
    final last = app.lastExportedAt;
    if (last == null) return '还没有导出过；数据只在这台手机里';
    final when = relativeTime(last);
    if (app.exportOverdue) {
      return '上次导出 $when，已超过 ${AppController.exportReminderDays} 天';
    }
    return '上次导出 $when';
  }

  /// 外观入口的副标题：一眼看出当前是哪套主题、深色怎么取、有没有背景图。
  String _appearanceSubtitle() {
    final prefs = app.prefs;
    final themeName = prefs.themeId == followBackgroundThemeId
        ? '跟随背景图'
        : presetOf(prefs.themeId).name;
    // 深色 / 亮色的取法**只在非"跟随系统"时写出来**：跟系统是默认值，
    // 每条副标题都缀一句"跟随系统"只会把真正有信息量的部分挤掉。
    final mode = prefs.themeMode == UiPrefs.defaultThemeMode
        ? ''
        : ' · ${themeModeLabel(prefs.themeMode)}';
    final background = prefs.hasBackground ? ' · 有背景图' : '';
    return '$themeName$mode$background';
  }

  /// 提醒入口的副标题：一眼看出开没开、当前是哪两档。
  ///
  /// 只列**开着**的档：关掉的那一档对"它现在会怎么提醒我"没有贡献，
  /// 摆出来反而要人多读一句才知道它不算数。
  String _reminderSubtitle() {
    if (!app.remindersSupported) return '电脑端不做提醒';
    if (!app.prefs.reminderEnabled) return '已关闭';
    final on = app.prefs.reminderLeads
        .where((lead) => lead.enabled)
        .toList(growable: false);
    if (on.isEmpty) return '开着，但两档都关掉了';
    return '提前 ${on.map((lead) => describeLeadMinutes(lead.minutes)).join('、')}';
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
      return Text('已关闭', style: Theme.of(context).textTheme.bodySmall);
    }
    return FutureBuilder<AiConfig>(
      future: _aiConfig,
      builder: (context, snapshot) {
        final config = snapshot.data;
        final String text;
        if (config == null) {
          text = '把实现清单整理成「如何解决」';
        } else if (config.isConfigured) {
          text = '已配置 · ${config.model}';
        } else {
          text = '未配置：${config.validate()}';
        }
        return Text(text, style: Theme.of(context).textTheme.bodySmall);
      },
    );
  }

  /// GitHub 备份同步入口的副标题。
  ///
  /// 与 AI 那一条同一套写法：**配置读不出来也只当装饰**，不阻塞整页。
  /// 记账（上次同步时间）是同步读的本地小文件，不必再起一个 `FutureBuilder`。
  Widget _gitHubSubtitle(BuildContext context) {
    if (!app.prefs.githubBackupEnabled) {
      return Text('已关闭', style: Theme.of(context).textTheme.bodySmall);
    }
    final owner = app.prefs.githubBackupOwner;
    final repo = app.prefs.githubBackupRepo;
    final record = app.readGitHubSyncRecord();

    final String text;
    if (owner.isEmpty || repo.isEmpty) {
      text = '未配置：还没填仓库所有者或仓库名';
    } else if (record == null) {
      text = '$owner/$repo · 还没同步过';
    } else {
      text = '$owner/$repo · 上次同步 ${formatStamp(record.syncedAt)}';
    }
    return Text(text, style: Theme.of(context).textTheme.bodySmall);
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
