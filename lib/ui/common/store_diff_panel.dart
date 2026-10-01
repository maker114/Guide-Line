import 'package:flutter/material.dart';

import '../../core/store/store_diff.dart';
import 'diff_colors.dart';
import 'labels.dart';

/// 版本差异面板：**把"两份数据差在哪"摆出来**。
///
/// 为什么要有它：同步 / 拉回 / 导入这几条路都是"整份覆盖"，覆盖前只给一句
/// "确定吗、条数从 12 变成 15"是不够的 —— 条数一样也可能换掉了一条，
/// 条数变多也可能顺手删了三条。这一屏回答的是"**具体哪几条**"。
///
/// 一屏只留四样东西，各有各的活：**图例**（哪块颜色是哪一边）、**一行总数**
/// （新增 / 删除 / 修改）、**逐条清单**、**一句后果**（`note`）。措辞按 2026-09-30
/// 的用户口径收短（需求①）：同一句话不说两遍，黄色那行只讲"怎么读"。
///
/// 三种颜色（2026-09-30 改定，需求③）：**绿＝新增、红＝删除、黄＝修改**。
/// 一处改动仍然是上下相邻的两行（上一行是旧、下一行是新，前缀 `−` / `+` 指方向），
/// 但两行**都是黄的** —— 用户撤回了原先"改动也一红一绿"的口径：红绿只留给
/// 真正动条数的动作，"多了、少了、还是只是改了"才一眼分得开。
/// 黄色的那两行底下还会补一句**改了什么**（"标题：写指南 → 写一本指南"）。
///
/// 基准由调用方给：看云端时会拿本机当基准（红/黄的是本机将被换掉的），
/// 上传前检查时拿云端当基准。
Future<DiffSheetResult> showStoreDiffSheet(
  BuildContext context, {
  required StoreDiff diff,
  required String title,
  required String baseLabel,
  required String targetLabel,
  String confirmLabel = '知道了',
  String? cancelLabel,
  bool danger = false,
  bool barrierDismissible = true,
  String? note,
  bool hideConfirm = false,
}) async {
  final result = await showModalBottomSheet<DiffSheetResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // 底部面板这边这个开关叫 `isDismissible`（`barrierDismissible` 是 `showDialog` 的名字）：
    // 启动比对那扇面板点空白不许关掉，就是靠它。
    isDismissible: barrierDismissible,
    builder: (sheetContext) => StoreDiffSheet(
      diff: diff,
      title: title,
      baseLabel: baseLabel,
      targetLabel: targetLabel,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      danger: danger,
      note: note,
      hideConfirm: hideConfirm,
    ),
  );
  // 没点按钮就关掉 = "我还没想好"，与点了「暂不推送」不是一回事：
  // 启动比对（需求⑤）靠这个差别决定要不要把那枚黄胶囊留在右上角。
  return result ?? DiffSheetResult.dismissed;
}

/// 用户在差异面板上点出来的结果。
enum DiffSheetResult {
  /// 主按钮（[StoreDiffSheet.confirmLabel]）—— 例如「覆盖云端数据」「推送」。
  confirm,

  /// 次按钮（[StoreDiffSheet.cancelLabel]）—— 例如「使用云端数据」「暂不推送」。
  cancel,

  /// 没点按钮就关掉了（返回键 / 划走 / 点面板外）—— 一个字节都没动。
  dismissed,
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
    this.hideConfirm = false,
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

  /// 把主按钮收起来，只留次按钮（[cancelLabel]）。
  ///
  /// 只有一个用它的地方：开机比对发现"本机 0 条、云端有东西"时，「覆盖云端数据」
  /// 是明令禁止的动作（见 `StartupSyncRequest.pullOnly`），那一支上只留
  /// 「使用云端数据」。按钮不是"禁用"，是**根本不存在** —— 摆一个灰按钮
  /// 仍然是在说"这件事你可以做，只是现在不行"。
  final bool hideConfirm;

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
                    background: colors.backgroundOf(DiffSide.previous),
                    foreground: colors.foregroundOf(DiffSide.previous),
                    text: baseLabel,
                  ),
                  const SizedBox(height: 4),
                  _Legend(
                    background: colors.backgroundOf(DiffSide.next),
                    foreground: colors.foregroundOf(DiffSide.next),
                    text: targetLabel,
                  ),
                  if (diff.modified > 0) ...<Widget>[
                    const SizedBox(height: 4),
                    _Legend(
                      background: colors.modifiedBackground,
                      foreground: colors.modifiedForeground,
                      text: '黄色成对出现：上一行是旧内容，下一行是新内容。',
                    ),
                  ],
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
                      onPressed: () =>
                          Navigator.of(context).pop(DiffSheetResult.cancel),
                      child: Text(cancelLabel!),
                    ),
                  if (!hideConfirm) ...<Widget>[
                    const SizedBox(width: 8),
                    FilledButton(
                      style: danger
                          ? FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.error)
                          : null,
                      onPressed: () =>
                          Navigator.of(context).pop(DiffSheetResult.confirm),
                      child: Text(confirmLabel),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 图例：一小块该类的颜色 + 它代表什么。
class _Legend extends StatelessWidget {
  const _Legend({
    required this.background,
    required this.foreground,
    required this.text,
  });

  final Color background;
  final Color foreground;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: background,
            border: Border.all(color: foreground),
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

/// 把字段变动写成一行："标题：写指南 → 写一本指南；等 3 处"。
///
/// 只写前两条（Q-3 定的口径）：那行小字是**提示**，不是清单 —— 十几条字段变动
/// 全铺开会把这一屏最要紧的"哪几条记录变了"挤没。一条都列不出来（变的只是
/// `updated_at` 这类被排除的噪声键）时如实说"内容有改动"，不编假说明。
String _changeText(List<FieldChange> changes) {
  if (changes.isEmpty) return '内容有改动';
  final shown = changes.take(2).map((change) => change.text).join('；');
  final rest = changes.length - 2;
  return rest > 0 ? '$shown；等 $rest 处' : shown;
}

/// 一行差异：底色说**是哪一类**（绿新增 / 红删除 / 黄修改），前缀说方向
/// （`−` 是上个版本那一行、`+` 是下个版本那一行），右边是这条记录的名字。
///
/// 修改的两行是同一件事的两面，所以"改了什么"只在**下面那一行**（新）底下写一次。
class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.entry, required this.colors});

  final DiffEntry entry;
  final DiffColors colors;

  @override
  Widget build(BuildContext context) {
    final foreground = colors.foregroundOfKind(entry.kind);
    final showChanges =
        entry.kind == DiffKind.modified && entry.side == DiffSide.next;
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.backgroundOfKind(entry.kind),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  entry.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground, fontSize: 14),
                ),
                if (showChanges)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      _changeText(entry.changes),
                      style: TextStyle(color: foreground, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
