import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/entity.dart';
import '../../core/models/enums.dart';
import '../../core/store/export_codec.dart';
import '../../platform/data_transfer_platform.dart';
import '../common/dialogs.dart';
import '../common/format.dart';

/// 导出 / 导入。
///
/// 没有云端之后，**导出是数据离开这台手机的唯一通道**（卸载 App、换机、手机丢失），
/// 所以这一页既要做通道，也要把"该导出了"这件事说清楚。
class ExportPage extends StatefulWidget {
  const ExportPage({super.key, required this.app, this.pickImportFile});

  final AppController app;

  /// 选文件的钩子（默认走系统文件选择器）。
  ///
  /// 留这个口子的理由很具体：`file_picker` 在纯 Dart 测试里没有插件实现，
  /// 而"导入前的确认框里到底摆了什么数"**只有走到这一步才验得出来** ——
  /// 而那几句文案恰恰是用户唯一的决策依据。
  final Future<PickedTransferFile?> Function()? pickImportFile;

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
      final pick = widget.pickImportFile ??
          () => DataTransferPlatform.pickFile(dialogTitle: '选择要导入的导出文件');
      picked = await pick();
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

    // 两侧都数**活记录**（墓碑不算）：用户要判断的是"看得见的数据会少掉多少"，
    // 而 `payload.counts` 是**含墓碑**的（导入本来就是整体替换、墓碑也要一起搬）。
    // 所以这一页自己数，不去改 core 层的口径 —— 这里的算法与
    // `Workspace.liveProjects` 那几个视图完全一样，两个数才可能对得上。
    final current = _currentCounts;
    final incoming = _liveCountsOf(payload);

    final ok = await confirmAction(
      context,
      title: '导入并替换全部数据',
      message: '文件名：${picked.name}\n'
          '导出时间：${payload.exportedAt == null ? '未知' : formatTimestamp(payload.exportedAt!)}\n'
          '\n'
          '当前：${_countsText(current)}\n'
          '文件：${_countsText(incoming)}\n'
          '${_netChangeText(_totalOf(current), _totalOf(incoming))}\n'
          '\n'
          '导入是整体替换，不会把两份数据合起来（把两份合起来的「合并导入」还没做）。\n'
          '想留住现在这份数据，先「导出并分享」留个档，再导入。\n'
          '替换前当前数据会先整体轮转进备份，可在「备份与恢复」里退回。',
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
    showToast(context, '已导入：${_countsText(incoming)}');
  }

  /// 当前库的活记录数：直接问 `Workspace.live*`（"活记录"口径的唯一出处）。
  _LiveCounts get _currentCounts => (
        projects: widget.app.ws.liveProjects.length,
        inspirations: widget.app.ws.liveInspirations.length,
        events: widget.app.ws.liveEvents.length,
        tasks: widget.app.ws.liveTasks.length,
      );
}

/// 四类记录的**活记录**条数（已删除的墓碑一律不算）。
typedef _LiveCounts = ({int projects, int inspirations, int events, int tasks});

/// 文件那一侧的活记录数。
///
/// `ExportPayload.counts` 是含墓碑的，这里**刻意不用它**：同一个确认框里
/// "当前"按活记录算、"文件"按含墓碑算的话，两个数根本对不上，
/// 比不给数字更糟（用户会以为自己看错了）。
_LiveCounts _liveCountsOf(ExportPayload payload) => (
      projects: _liveItemCount(payload, DocName.projects),
      inspirations: _liveItemCount(payload, DocName.inspirations),
      events: _liveItemCount(payload, DocName.events),
      tasks: _liveItemCount(payload, DocName.tasks),
    );

int _liveItemCount(ExportPayload payload, DocName name) =>
    payload.store.documentOf(name).items.where((item) => !item.deleted).length;

int _totalOf(_LiveCounts counts) =>
    counts.projects + counts.inspirations + counts.events + counts.tasks;

String _countsText(_LiveCounts counts) =>
    '项目 ${counts.projects} · 灵感 ${counts.inspirations} · '
    '事件 ${counts.events} · 任务 ${counts.tasks}';

/// 净变化那一句 —— 用户最需要的其实是"会不会少东西"。
String _netChangeText(int currentTotal, int incomingTotal) {
  final delta = incomingTotal - currentTotal;
  if (delta == 0) return '条数相当（前后都是 $currentTotal 条）';
  if (delta < 0) {
    return '总条数将减少 ${-delta} 条（$currentTotal → $incomingTotal）';
  }
  return '总条数将增加 $delta 条（$currentTotal → $incomingTotal）';
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
