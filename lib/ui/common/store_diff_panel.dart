import 'package:flutter/material.dart';

import '../../core/store/store_diff.dart';
import 'diff_colors.dart';
import 'labels.dart';

/// 版本差异面板：**把"两份数据差在哪"摆出来**（红＝上个版本、绿＝下个版本）。
///
/// 为什么要有它：同步 / 拉回 / 导入这几条路都是"整份覆盖"，覆盖前只给一句
/// "确定吗、条数从 12 变成 15"是不够的 —— 条数一样也可能换掉了一条，
/// 条数变多也可能顺手删了三条。这一屏回答的是"**具体哪几条**"。
///
/// 口径与 git 一致（2026-09-30 定）：一处改动就是红绿相邻的一对，
/// 不做字段级 diff，也没有第三种颜色。基准由调用方给：
/// 看云端时会拿本机当基准（红的是本机将被换掉的），上传前检查时拿云端当基准。
Future<bool> showStoreDiffSheet(
  BuildContext context, {
  required StoreDiff diff,
  required String title,
  required String baseLabel,
  required String targetLabel,
  String confirmLabel = '知道了',
  String? cancelLabel,
  bool danger = false,
  String? note,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => StoreDiffSheet(
      diff: diff,
      title: title,
      baseLabel: baseLabel,
      targetLabel: targetLabel,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      danger: danger,
      note: note,
    ),
  );
  return result ?? false;
}

/// 面板本体，独立出来是为了能直接进 widget 测试（不必先弹一遍 sheet）。
class StoreDiffSheet extends StatelessWidget {
  const StoreDiffSheet({
    super.key,
    required this.diff,
    required this.title,
    required this.baseLabel,
    required this.targetLabel,
    this.confirmLabel = '知道了',
    this.cancelLabel,
    this.danger = false,
    this.note,
  });

  final StoreDiff diff;
  final String title;

  /// 上个版本（红）是什么，例如「云端 · 2026-09-30 12:00 · 12 条」。
  final String baseLabel;

  /// 下个版本（绿）是什么，例如「本机 · 现在 · 15 条」。
  final String targetLabel;

  final String confirmLabel;
  final String? cancelLabel;
  final bool danger;

  /// 底下补一句"接下来会发生什么"（覆盖方向、会不会先备份）。
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colors = DiffColors.ofContext(context);
    final theme = Theme.of(context);
    final changed = diff.changed.toList(growable: false);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _Legend(
                    side: DiffSide.previous,
                    text: baseLabel,
                    colors: colors,
                  ),
                  const SizedBox(height: 4),
                  _Legend(
                    side: DiffSide.next,
                    text: targetLabel,
                    colors: colors,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    diff.hasChanges ? diff.changeSummary : '两份没有差别',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Flexible(
              child: changed.isEmpty
                  ? const SizedBox.shrink()
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      children: <Widget>[
                        for (final collection in changed) ...<Widget>[
                          _CollectionHeader(collection: collection),
                          for (final entry in collection.entries)
                            _DiffRow(entry: entry, colors: colors),
                          const SizedBox(height: 12),
                        ],
                      ],
                    ),
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  note!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  if (cancelLabel != null)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(cancelLabel!),
                    ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: danger
                        ? FilledButton.styleFrom(
                            backgroundColor: theme.colorScheme.error)
                        : null,
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(confirmLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 图例：一小块该侧的颜色 + 它代表哪个版本。
class _Legend extends StatelessWidget {
  const _Legend({required this.side, required this.text, required this.colors});

  final DiffSide side;
  final String text;
  final DiffColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: colors.backgroundOf(side),
            border: Border.all(color: colors.foregroundOf(side)),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({required this.collection});

  final CollectionDiff collection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (collection.added > 0) '新增 ${collection.added}',
      if (collection.removed > 0) '删除 ${collection.removed}',
      if (collection.modified > 0) '修改 ${collection.modified}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '${docNameLabel(collection.doc)} · ${parts.join(' · ')}',
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 一行差异：底色说红绿，前缀说加减，右边是这条记录的名字。
class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.entry, required this.colors});

  final DiffEntry entry;
  final DiffColors colors;

  @override
  Widget build(BuildContext context) {
    final foreground = colors.foregroundOf(entry.side);
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.backgroundOf(entry.side),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 16,
            child: Text(
              entry.side == DiffSide.next ? '+' : '−',
              style: TextStyle(color: foreground, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Text(
              entry.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: foreground, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
