import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/store/app_storage.dart';
import '../common/dialogs.dart';
import '../common/format.dart';

/// 备份与恢复。
///
/// 没有云端之后，**本地备份就是唯一的安全网**，所以这一页要把策略讲清楚：
///   · 每次保存前先把旧文件轮转进滚动备份（最近 10 份）；
///   · 每天第一份保存留一个日快照（最近 7 天）；
///   · 恢复前会先轮转当前数据 —— **恢复动作本身也可回退**。
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
                subtitle: const Text('把当前数据写入主文件，并把旧文件轮转进备份'),
                onTap: () => _snapshot(context),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  '可用备份 ${backups.length} 份（新 → 旧）。恢复前会先把当前数据轮转进备份，'
                  '所以恢复错了还可以再恢复回来。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (backups.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('还没有备份。保存过一次数据后就会出现。'),
                )
              else
                for (final entry in backups)
                  ListTile(
                    leading: Icon(
                      entry.kind == BackupKind.daily ? Icons.today_outlined : Icons.history,
                    ),
                    title: Text(entry.label),
                    subtitle: Text(
                      '${formatTimestamp(entry.modifiedAt)} · ${_formatBytes(entry.sizeBytes)}',
                      style: theme.textTheme.labelSmall,
                    ),
                    trailing: TextButton(
                      onPressed: () => _restore(context, entry),
                      child: const Text('恢复'),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }

  void _snapshot(BuildContext context) {
    app.ws.snapshotNow();
    showToast(context, '已写入一份备份');
  }

  Future<void> _restore(BuildContext context, BackupEntry entry) async {
    final ok = await confirmAction(
      context,
      title: '从备份恢复',
      message: '当前数据会被替换为「${entry.label}」（${formatTimestamp(entry.modifiedAt)}）。\n'
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

  static String _formatBytes(int bytes) {
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(2)} MB';
  }
}
