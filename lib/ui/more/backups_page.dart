import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/store/app_paths.dart';
import '../../core/store/app_storage.dart';
import '../common/dialogs.dart';

/// 备份与恢复。
///
/// 没有云端之后，**本地备份就是唯一的安全网**，所以这一页要把策略讲清楚：
///   · 备份按**一段完整操作**留：进编辑页面后第一次落盘时把"进页面之前"轮转一份，
///     离开页面时结算 —— 页面里改多少笔都只留那一份（2026-09-26 起）；
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
                subtitle: const Text('把当前数据写入主文件，并立刻轮转出一份备份（不等最小间隔）'),
                onTap: () => _snapshot(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '备份代表「一段完整操作」：进编辑页面后第一次落盘时留一份，离开页面时结算。'
                  '滚动备份只保留 ${AppPaths.rollingBackupCount} 份，'
                  '会被后续保存一份份覆盖 —— 想反悔要尽快。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const Divider(),
              if (backups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('还没有备份。随便改点什么存一次，它就会出现 —— 没有云端时，它是唯一的安全网。'),
                )
              else
                for (final entry in backups)
                  ListTile(
                    leading: Icon(
                      entry.kind == BackupKind.daily ? Icons.today_outlined : Icons.history,
                    ),
                    title: Text(entry.label),
                    // 时间已经在标签里了（`上一份 · 09-26 11:57 · 42 条`），
                    // 副标题只补体积 —— 同一行里把时间写两遍反而更难扫。
                    subtitle: Text(
                      _formatBytes(entry.sizeBytes),
                      style: theme.textTheme.labelSmall,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        TextButton(
                          onPressed: () => _restore(context, entry),
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

  Future<void> _restore(BuildContext context, BackupEntry entry) async {
    final ok = await confirmAction(
      context,
      title: '从备份恢复',
      message: '当前数据会被替换为「${entry.label}」。\n'
          '当前数据会先轮转进备份，所以这一步可以再恢复回来。',
      confirmLabel: '恢复',
      danger: true,
    );
    if (!ok || !context.mounted) return;

    final error = app.restoreBackup(entry.path);
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已恢复到「${entry.label}」');
  }

  Future<void> _delete(BuildContext context, BackupEntry entry) async {
    final ok = await confirmAction(
      context,
      title: '删除备份',
      message: '删除「${entry.label}」。\n'
          '这一步不可撤销；恢复不到这一份了。至少会保留一份备份。',
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
