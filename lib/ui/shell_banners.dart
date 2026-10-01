import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../platform/data_directory.dart';
import 'common/dialogs.dart';
import 'more/upcoming_page.dart';
import 'theme/shape_tokens.dart';

/// 外壳级的横幅、以及它们点开之后那两个对话 —— **手机外壳与桌面外壳共用这一份**。
///
/// 为什么要单独一个文件：这两条横幅（启动告警、逾期提醒）与它们点开的对话框
/// 原来都是 `app_shell.dart` 里的私有实现。桌面外壳同样要摆这两条，
/// 再抄一遍就是**两份会各自漂**的实现（文案改一处、另一处不变），
/// 所以提上来做成公开的，两边引同一份。
///
/// 布局差别的处理：横幅自带外边距（12, 8, 12, 0），是照手机那套"贴着标题栏
/// 下面一张卡片"写的；桌面外壳整块内容区就在标题栏下方，同一套外边距照样成立，
/// 所以没有再开参数。

/// 启动告警条（数据文件损坏、从备份恢复、回收站到期清理之类）。
///
/// 做成**带外边距的卡片**而不是通栏色带（实机反馈："顶部标题栏偶尔背景颜色
/// 不一样"）：通栏色带紧贴在标题栏下面，看着像是标题栏自己变了色；
/// 而且满色的 `errorContainer` 违反"底色一律中性灰"这条主题约定。
///
/// 两种交互，按告警的性质给：
///   · 数据事故（损坏 / 恢复）——**整条可点**，点开是"出了什么事、怎么办"，
///     末尾还带一个「一键导出」。只有一行小字时用户能做的顶多是"哦"一声；
///   · 维护提示（回收站清理）——**可关掉**。它没有"下一步动作"，
///     但要让人确认自己看见了。
class ShellWarningBanner extends StatelessWidget {
  const ShellWarningBanner({
    super.key,
    required this.messages,
    this.onTap,
    this.onDismiss,
  });

  final List<String> messages;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.warning_amber_outlined,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              messages.join('；'),
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: '知道了',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: onDismiss,
            )
          else if (onTap != null)
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.outline,
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHigh,
        child: onTap == null
            ? row
            : InkWell(
                borderRadius: BorderRadius.circular(AppShapes.cardRadius),
                onTap: onTap,
                child: row,
              ),
      ),
    );
  }
}

/// 逾期提醒条。
///
/// 不做推送唤醒（ADR-062），所以"提醒"只能在用户打开 App 时发生：
/// 这条横幅 + 「更多」上的角标，就是这个 App 全部的到期提醒手段。
///
/// 与告警条一样做成卡片：**底部色带贴在标题栏下面会被当成标题栏变色**
/// （实机反馈），而且它的底色也不该跟着主题色跑。
class ShellDueBanner extends StatelessWidget {
  const ShellDueBanner({super.key, required this.count, required this.app});

  final int count;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHigh,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppShapes.cardRadius),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => UpcomingTasksPage(app: app)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '有 $count 条任务已逾期',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「关于」对话框：名称、版本号、数据目录。
///
/// 数据目录**就在这儿写着**（而不是藏在设置里）：两端各存各的一份数据，
/// "我这份到底写在哪"是用户最常问、也最该一眼看到的一件事。
void showAboutApp(BuildContext context, AppController app) {
  showAboutDialog(
    context: context,
    applicationName: AppInfo.displayName,
    applicationVersion: AppInfo.versionLabel,
    children: <Widget>[
      const Text('本地优先的个人生活管理工具，Android 单机版 + Windows 桌面版。'),
      const SizedBox(height: 8),
      Text('数据目录：${app.dataDirectory.path}'),
    ],
  );
}

/// 数据事故的详情（Q16）：从哪一份备份恢复的、隔离文件叫什么，以及"先导出一份"。
///
/// 告警条原来只有一行不可点的小字，用户看完最多"哦"一声；而事故之后**最该做的一件事
/// 恰恰是导出**（那是数据离开这台设备的主要通道）。所以这里把话说全，
/// 并且把导出动作直接放在手边。
Future<void> showDataIncident(
  BuildContext context,
  AppController app,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('数据恢复记录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final line in app.dataIncidentLines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('· $line'),
              ),
            const SizedBox(height: 6),
            Text(
              '这些文件都在应用私有目录：${app.dataDirectory.path}\n'
              '隔离的原文件不会被覆盖，也不会自动删除；备份仍可在「备份与恢复」里查看。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            if (app.exportOverdue) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '导出提醒已重新开始计时，发生事故后请优先导出一份。',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('知道了'),
        ),
        // 能点的用胶囊（《界面规范》§2）：`FilledButton` 的默认形状就是胶囊
        FilledButton(
          onPressed: () async {
            Navigator.of(dialogContext).pop();
            final result = await app.exportAndShare();
            if (context.mounted) {
              showToast(context, result.message, error: !result.ok);
            }
          },
          child: const Text('一键导出'),
        ),
      ],
    ),
  );
}
