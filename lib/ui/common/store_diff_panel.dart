import 'package:flutter/material.dart';

import '../../core/json/store_file.dart';
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
  StoreFile? baseStore,
  StoreFile? targetStore,
  String baseCommit = '',
  String targetCommit = '',
  String? cloudLine,
  String? localLine,
  String? footnote,
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
      baseStore: baseStore,
      targetStore: targetStore,
      baseCommit: baseCommit,
      targetCommit: targetCommit,
      cloudLine: cloudLine,
      localLine: localLine,
      footnote: footnote,
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
    this.baseStore,
    this.targetStore,
    this.baseCommit = '',
    this.targetCommit = '',
    this.cloudLine,
    this.localLine,
    this.footnote,
  });

  /// 两边的数据文件（2026-10-02 加）：给了就在标题下面摆**两行对照**。
  ///
  /// 为什么放在这里而不是各自算：那两行要报的是"云端 / 本地各有几条活记录、
  /// 几条归档、提交码是哪个"，其中**云端的数只有读过云端的地方才有**。
  /// 调用方本来就已经拿到两边了（`StartupSyncRequest.diff` 的 base/target 就是
  /// 那两份数据），所以让它顺手递进来，比面板自己再联网读一次干净。
  final StoreFile? baseStore;
  final StoreFile? targetStore;

  /// 两边的提交码（前 7 位；空串 = 读不到 ⇒ 那两行显示 `-------`）。
  final String baseCommit;
  final String targetCommit;

  /// 开头那两行对照（2026-10-02 用户口径）：**云端永远是第一行、本地永远是第二行**。
  ///
  /// 为什么不在这里自己从 `baseStore` / `targetStore` 算：那两份数据的角色
  /// 随场景翻转（推送时 base=云端，拉取时 base=本机）——
  /// 面板自己按 base/target 打标签，**推送那扇就会把云端排到第二行**，
  /// 与"云端在上、本地在下"的固定读法相反。所以由调用方给**已经写好的两行文字**，
  /// 顺序与标签都在调用处定死（它们本来就已经拿着那两份数据）。
  final String? cloudLine;
  final String? localLine;

  /// 摆在两行对照**下面**的一句补充（2026-10-02 加）。
  ///
  /// 为什么需要它：给了 [baseStore] / [targetStore] 之后，[baseLabel] / [targetLabel]
  /// 按设计不再显示（那是退回用的图例），于是它们原来带的**时间戳**就丢了 ——
  /// "云端那份最后改于什么时候"是判断"要不要拉"的重要一条，不能因为改版丢掉。
  /// 所以由调用方把那一句（例如"云端那份的最后修改时间：…"）单独递进来。
  final String? footnote;

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
                  // 2026-10-02（用户口径）：**不再解释三种颜色**，开头直接摆两行对照 ——
                  //   云端：项目 12 · 灵感 9 · 事件 4 · 任务 23 · 已归档 7 · 提交码 a2dd62b
                  //   本地：项目 12 · 灵感 9 · 事件 4 · 任务 23 · 已归档 7 · 提交码 a2dd62b
                  // 颜色仍然照用（行还是绿/红/黄），只是不再花两行去讲它们是什么意思 ——
                  // "哪块颜色是哪一边"由这两行的**先后顺序**（云端在前、本地在后）说明。
                  if (cloudLine != null) _CountLine(line: cloudLine!),
                  if (localLine != null) ...<Widget>[
                    const SizedBox(height: 2),
                    _CountLine(line: localLine!),
                  ],
                  if (cloudLine == null &&
                      localLine == null &&
                      baseStore == null &&
                      targetStore == null) ...<Widget>[
                    // 没给两行对照时退回原来的两句（"哪一边是哪一边"仍然要说清）。
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
                  ],
                  if (footnote != null && footnote!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      footnote!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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

/// 一行"云端：项目 12 · 灵感 9 · 事件 4 · 任务 23 · 已归档 7 · 提交码 a2dd62b"。
///
/// 与 [_Legend] 的区别：那个是"一块颜色 + 它代表哪一边"（已经不用了，用户口径：
/// **不再解释三种颜色**），这个是**两边的实际条数与提交码**，一行说完。
class _CountLine extends StatelessWidget {
  const _CountLine({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      line,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurface,
        // 这一行信息密度高（六个段），等宽字在窄屏上更好逐段对读。
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
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
