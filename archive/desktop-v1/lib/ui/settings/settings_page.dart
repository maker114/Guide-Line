import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../features/portability.dart';
import '../../platform/data_directory.dart';

/// 设置页：数据位置、版本、同步状态、导出 / 导入。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.app});

  final AppController app;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _importPath = TextEditingController();
  String? _lastExportPath;
  String? _notice;
  bool _noticeIsError = false;
  ImportPreviewResult? _preview;
  String? _previewPath;
  List<String> _applied = <String>[];
  List<String> _drafts = <String>[];

  @override
  void dispose() {
    _importPath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: <Widget>[
        if (_notice != null) ...<Widget>[
          Material(
            color: _noticeIsError
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Icon(_noticeIsError ? Icons.error_outline : Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_notice!)),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _notice = null),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        Text('数据', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _Kv(label: '数据目录', value: app.dataDirectory.path, copyable: true),
        _Kv(
          label: '文档版本',
          value: DocName.values
              .map((n) => '${n.fileName} v${app.ws.versionOf(n)}')
              .join(' · '),
        ),
        _Kv(label: '本地统计',
            value: '项目 ${app.projectCount} · 灵感 ${app.inspirationCount} · '
                '事件 ${app.eventCount} · 任务 ${app.taskCount} · 归档区 ${app.archiveCount}'),
        const Divider(height: 28),

        Text('同步', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _Kv(label: '当前状态', value: app.hasCloud ? app.syncStatus.label : '本地模式（尚未配置云端）'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: () async {
                  final message = await app.syncNow();
                  setState(() {
                    _notice = message ?? '同步完成';
                    _noticeIsError = message != null;
                  });
                },
                icon: const Icon(Icons.sync),
                label: const Text('立即同步'),
              ),
              const SizedBox(width: 12),
              Text(
                '云端后端待定；在此之前应用以「本地模式」完整可用，\n'
                '两端之间可用下面的导出 / 导入手动搬移。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const Divider(height: 28),

        Text('导出', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: () {
                final path = app.exportTo(app.defaultExportPath());
                setState(() {
                  _lastExportPath = path;
                  _notice = '已导出到：$path';
                  _noticeIsError = false;
                });
              },
              icon: const Icon(Icons.save_alt),
              label: const Text('导出为 .json.gz'),
            ),
            const SizedBox(width: 12),
            if (_lastExportPath != null)
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _lastExportPath!));
                  setState(() => _notice = '路径已复制到剪贴板');
                },
                icon: const Icon(Icons.copy),
                label: const Text('复制路径'),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '导出包含全部四份文档、版本号、墓碑与墓碑骨架（含已删除内容，便于完整还原）。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        const Divider(height: 28),

        Text('导入', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _importPath,
                decoration: const InputDecoration(
                  labelText: '导出文件路径（可把另一台设备的文件拷到数据目录下的 exports/）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () => _preview_(app, _importPath.text.trim()),
              child: const Text('预检'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_exportCandidates(app).isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final path in _exportCandidates(app))
                ActionChip(
                  avatar: const Icon(Icons.insert_drive_file_outlined, size: 16),
                  label: Text(path.split(Platform.pathSeparator).last),
                  onPressed: () {
                    _importPath.text = path;
                    _preview_(app, path);
                  },
                ),
            ],
          ),
        if (_preview != null) ...<Widget>[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('预检结果', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  for (final decision in _preview!.decisions)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '· ${decision.name.fileName}：${_actionLabel(decision.action)}'
                        ' —— ${decision.detail}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      FilledButton(
                        onPressed: () => _apply_(app, _previewPath!),
                        child: const Text('应用导入'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _preview!.hasConflict
                            ? '存在冲突：本地有未提交改动，将**保留本地**并把导入内容存为草稿'
                            : '无冲突，可直接应用',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
        if (_applied.isNotEmpty || _drafts.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text('已应用的文档：${_applied.join('、')}', style: theme.textTheme.bodySmall),
          if (_drafts.isNotEmpty)
            Text('草稿留底：${_drafts.length} 个（见归档区 → 本地草稿）',
                style: theme.textTheme.bodySmall),
        ],
        const Divider(height: 28),

        Text('关于', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        _Kv(label: '版本', value: '${AppInfo.version}+${AppInfo.buildNumber}'),
        _Kv(label: '数据契约', value: 'docs/spec/数据契约.md（字段顺序即写出顺序）'),
        _Kv(label: '架构边界', value: 'core 不依赖 Flutter · 三层不出现云端 SDK · 平台判断只在 platform/ui'),
      ],
    );
  }

  List<String> _exportCandidates(AppController app) {
    final dir = Directory('${app.dataDirectory.path}${Platform.pathSeparator}exports');
    if (!dir.existsSync()) return <String>[];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json.gz'))
        .map((f) => f.path)
        .toList(growable: false);
    files.sort();
    return files.reversed.toList(growable: false);
  }

  void _preview_(AppController app, String path) {
    if (path.isEmpty) {
      setState(() {
        _notice = '请先选择或填写导出文件路径';
        _noticeIsError = true;
      });
      return;
    }
    final preview = app.previewImport(path);
    setState(() {
      _preview = preview;
      _previewPath = path;
      _applied = <String>[];
      _drafts = <String>[];
      if (!preview.ok) {
        _notice = '无法读取导出包：${preview.error}';
        _noticeIsError = true;
      } else {
        _notice = null;
      }
    });
  }

  void _apply_(AppController app, String path) {
    final report = app.applyImport(path);
    setState(() {
      if (report == null) {
        _notice = '导入失败';
        _noticeIsError = true;
        return;
      }
      _applied = report.applied.map((d) => d.fileName).toList(growable: false);
      _drafts = report.draftPaths;
      _notice = '导入完成：应用 ${_applied.length} 份文档，草稿 ${_drafts.length} 个';
      _noticeIsError = false;
    });
  }

  static String _actionLabel(ImportAction action) {
    switch (action) {
      case ImportAction.identical:
        return '内容相同';
      case ImportAction.takeIncoming:
        return '采用导入包';
      case ImportAction.keepLocal:
        return '保留本地';
      case ImportAction.conflict:
        return '冲突';
    }
  }
}

class _Kv extends StatelessWidget {
  const _Kv({required this.label, required this.value, this.copyable = false});

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Expanded(child: SelectableText(value, style: theme.textTheme.bodySmall)),
          if (copyable)
            IconButton(
              tooltip: '复制',
              iconSize: 16,
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            ),
        ],
      ),
    );
  }
}
