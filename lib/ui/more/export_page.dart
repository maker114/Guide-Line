import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/entity.dart';
import '../../core/store/export_codec.dart';
import '../../platform/data_transfer_platform.dart';
import '../common/dialogs.dart';
import '../common/format.dart';

/// 导出 / 导入。
///
/// 没有云端之后，**导出是数据离开这台手机的唯一通道**（卸载 App、换机、手机丢失），
/// 所以这一页既要做通道，也要把"该导出了"这件事说清楚。
class ExportPage extends StatefulWidget {
  const ExportPage({super.key, required this.app});

  final AppController app;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final app = widget.app;
        final theme = Theme.of(context);
        final last = app.lastExportedAt;

        return Scaffold(
          appBar: AppBar(title: const Text('导出 / 导入')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: <Widget>[
              Card(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            app.exportOverdue ? Icons.warning_amber_outlined : Icons.verified_outlined,
                            size: 18,
                            color: app.exportOverdue
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              last == null
                                  ? '还没有导出过'
                                  : '上次导出：${formatTimestamp(last)}（${relativeTime(last)}）',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: app.exportOverdue ? theme.colorScheme.error : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        app.exportOverdue
                            ? '建议每 ${AppController.exportReminderDays} 天导出一次 —— '
                                '这个 App 没有云端，手机丢了或卸载了，数据就只剩这份导出。'
                            : '导出的备份还不算旧，保持这个节奏就好。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('导出并分享'),
                subtitle: const Text('导出为 .json.gz 后交给系统分享（微信 / 邮件 / 网盘 / 电脑）'),
                enabled: !_busy,
                onTap: _busy ? null : () => _export(context),
              ),
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('从文件导入'),
                subtitle: const Text('整体替换当前数据，替换前会自动留一份备份'),
                enabled: !_busy,
                onTap: _busy ? null : () => _import(context),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(child: CircularProgressIndicator()),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('说明', style: theme.textTheme.labelLarge),
              ),
              const _Bullet('导出内容是全部四类记录（含已归档与回收站），不含界面偏好。'),
              const _Bullet('文件名形如 guideline-20260923-134500.json.gz，gzip 压缩的 JSON，'
                  '每条记录的字段与《数据契约》完全一致。'),
              const _Bullet('导入是整体替换，不是合并；替换前当前数据会先轮转进滚动备份，'
                  '导错了可以在「备份与恢复」里退回来。'),
              const _Bullet('导出文件只写在应用私有目录，分享时由系统按次授权给目标 App 读取，'
                  '不需要存储权限，也不会被别的 App 扫到。'),
              const _Bullet('电脑端导出的旧格式（v1 四文档信封）也能直接导入。'),
            ],
          ),
        );
      },
    );
  }

  Future<void> _export(BuildContext context) async {
    setState(() => _busy = true);
    final result = await widget.app.exportAndShare();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!context.mounted) return;
    showToast(context, result.message, error: !result.ok);
  }

  Future<void> _import(BuildContext context) async {
    setState(() => _busy = true);
    PickedTransferFile? picked;
    try {
      picked = await DataTransferPlatform.pickFile(
        dialogTitle: '选择要导入的导出文件',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (context.mounted) showToast(context, '打开文件选择器失败：$error', error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (picked == null || !context.mounted) return;

    final issues = DecodeIssues();
    final payload = ExportCodec.decode(picked.bytes, issues);
    if (!payload.readable) {
      final reason = issues.errors.isEmpty ? '结构不完整' : issues.errors.first;
      showToast(context, '这个文件里读不出 Guide Line 数据：$reason', error: true);
      return;
    }

    final ok = await confirmAction(
      context,
      title: '导入并替换全部数据',
      message: '文件：${picked.name}\n'
          '导出时间：${payload.exportedAt == null ? '未知' : formatTimestamp(payload.exportedAt!)}\n'
          '内容：${payload.countSummary}\n\n'
          '当前数据会先整体轮转进备份（可在「备份与恢复」退回），然后被这份文件替换。',
      confirmLabel: '整体替换',
      danger: true,
    );
    if (!ok || !context.mounted) return;

    final error = widget.app.applyImport(payload.store);
    if (!context.mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    showToast(context, '已导入：${payload.countSummary}');
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('· ', style: theme.textTheme.bodySmall),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
