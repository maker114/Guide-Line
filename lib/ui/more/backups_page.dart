import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/json/store_file.dart';
import '../../core/models/enums.dart';
import '../../core/store/app_paths.dart';
import '../../core/store/app_storage.dart';
import '../../core/store/github_sync.dart';
import '../../core/store/store_diff.dart';
import '../common/dialogs.dart';
import '../common/labels.dart';
import '../common/store_diff_panel.dart';

/// 备份与恢复。
///
/// 没有云端之后，**本地备份就是唯一的安全网**，所以这一页要把策略讲清楚：
///   · 备份按**一段完整操作**留：进编辑页面后的**第一笔落盘之前**轮转一份
///     （内容是"进这个页面之前"的版本），之后这一段里再改多少笔都不再留；
///     离开页面只结算会话标记（`AppStorage.endEditSession`），**不产生新备份**（2026-09-26 起）；
///   · 不在编辑页面里的散点保存按**最小间隔**节流；每天第一份轮转留一个日快照（最近 7 天）；
///   · 恢复前会强制轮转当前数据 —— **恢复动作本身也可回退**。
///
/// 由此推出两条用户必须知道的事，界面上一并说清：备份**代表一段操作**（不是每次保存），
/// 而且滚动备份只有 10 份、**会随后续保存被覆盖，想反悔要尽快**。
class BackupsPage extends StatelessWidget {
  const BackupsPage({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final backups = app.backups;
        final theme = Theme.of(context);

        return Scaffold(
          appBar: AppBar(title: const Text('备份与恢复')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('数据文件'),
                subtitle: Text('${app.storeFileSize}\n${app.dataDirectory.path}'),
                isThreeLine: true,
              ),
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('立即备份一份'),
                subtitle: const Text('立刻存一次并留一份备份，不等最小间隔'),
                onTap: () => _snapshot(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  // 只留"会被覆盖、想反悔要尽快"这一句：它是丢失风险
                  '滚动备份只保留 ${AppPaths.rollingBackupCount} 份，'
                  '会被后续保存依次覆盖；如需恢复到较早的备份请尽快。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const Divider(),
              if (backups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('还没有备份'),
                )
              else
                for (final entry in backups)
                  ListTile(
                    leading: Icon(
                      entry.kind == BackupKind.daily ? Icons.today_outlined : Icons.history,
                    ),
                    title: Text(entry.label),
                    // 时间与条数都在标签里了（`备份0930-21:49-123条`），
                    // 副标题只补体积 —— "点开能看差在哪"由点击本身回答，不必写在行里。
                    subtitle: Text(
                      _formatBytes(entry.sizeBytes),
                      style: theme.textTheme.labelSmall,
                    ),
                    onTap: () => _showDiff(context, entry),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        TextButton(
                          // 「恢复」与点开这一行是**同一条路**：先摆差异，
                          // 看过之后在那一屏上按「恢复这份」才真的换数据。
                          onPressed: () => _showDiff(context, entry),
                          child: const Text('恢复'),
                        ),
                        // 删除只对**滚动备份**开放：日快照是"某一天的留档"，
                        // 删掉就再也拿不回那天的样子了，交给自动裁剪（保留 7 天）即可。
                        if (entry.kind == BackupKind.rolling)
                          IconButton(
                            tooltip: '删除这份备份',
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () => _delete(context, entry),
                          ),
                      ],
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }

  void _snapshot(BuildContext context) {
    // 走 `snapshotBackupNow`（存储层的强制轮转）而不是 `ws.snapshotNow()`：
    // 那个走的是 `save()` 的节流路径，按钮上写着"立刻留一份"却可能被节流跳过。
    final error = app.snapshotBackupNow();
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已写入一份备份');
  }

  /// 点开一份备份（或者按「恢复」）：**先把"它和现在差在哪"摆出来**，
  /// 再让人在那一屏上决定要不要恢复。两条路走的是同一个方法 ——
  /// 恢复是覆盖性动作，**和现在不一样才让人看见差异再点**（用户口径）。
  ///
  /// 懒加载（点开才读盘）：备份有十几份，进页面就把每一份都读出来解析一遍、
  /// 只为在列表里摆个数字，不值。方向是"恢复之后手机上会变成什么样"——
  /// 基准＝现在（红＝会被换掉的），对方＝那份备份（绿＝恢复后会有的）。
  /// 和现在一模一样时只说一句，连面板都不摆（没什么可看的）。
  Future<void> _showDiff(BuildContext context, BackupEntry entry) async {
    final backup = app.readBackupStore(entry.path);
    if (backup == null) {
      showToast(context, '这份备份里读不出可用的数据', error: true);
      return;
    }
    final local = app.ws.buildStoreFile();
    final diff = diffStores(base: local, target: backup);
    if (!diff.hasChanges) {
      showToast(context, '「${entry.label}」和现在的数据一模一样');
      return;
    }
    final choice = await showStoreDiffSheet(
      context,
      diff: diff,
      title: '「${entry.label}」与现在的差别',
      baseLabel: '现在 · 会被换掉 · ${_countsText(local)}',
      targetLabel: '这份备份 · 恢复后即为该状态 · ${_countsText(backup)}',
      confirmLabel: '恢复这份',
      cancelLabel: '取消',
      danger: true,
      note: '恢复之前，当前数据会先整体轮转进备份，这一步可以再次恢复。',
    );
    if (choice != DiffSheetResult.confirm || !context.mounted) return;
    _applyRestore(context, entry);
  }

  /// 真正落盘那一步 —— 差异面板上按了「恢复这份」才走到这里。
  void _applyRestore(BuildContext context, BackupEntry entry) {
    final error = app.restoreBackup(entry.path);
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已恢复到「${entry.label}」');
  }

  /// 面板顶部那两行说明里的条数（活记录，与列表标签里的条数同源）。
  static String _countsText(StoreFile store) {
    final counts = liveCountsOf(store);
    return DocName.values
        .map((name) => '${docNameLabel(name)} ${counts[name] ?? 0}')
        .join(' · ');
  }

  Future<void> _delete(BuildContext context, BackupEntry entry) async {
    final ok = await confirmAction(
      context,
      title: '删除备份',
      message: '删除「${entry.label}」。\n'
          '这一步不可撤销，该备份将无法恢复。至少会保留一份备份。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    // 允许删到一份不剩是被存储层拒绝的，这里如实把原因显示出来
    final error = app.deleteBackup(entry.path);
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已删除「${entry.label}」');
  }

  static String _formatBytes(int bytes) {
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(2)} MB';
  }
}
