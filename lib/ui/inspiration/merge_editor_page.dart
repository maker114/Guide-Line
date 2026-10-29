import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/inspiration.dart';
import '../../core/models/project.dart';
import '../../core/models/project_item.dart';
import '../common/dialogs.dart';
import '../common/project_picker.dart';

/// 合并编辑器交回去的结果：**这次要并进清单的条目文本**（顺序即落盘顺序）。
///
/// 2026-10-29 重做合并界面后，合并只剩**一个落点：目标的「实现清单」** ——
/// 从前那三种选择（手改正文 / 追加原文 / 作为清单条目）连同"新正文"这个字段
/// 一起删掉了，所以这里只带回一件事：按顺序的条目文本。
class MergeResult {
  const MergeResult({required this.itemTexts});

  /// 与带进编辑器的灵感**一一对应**，顺序就是落进清单的顺序。
  final List<String> itemTexts;
}

/// 合并预览页（**手机端形态**）：把灵感并进目标，页面只做**预览 + 确认**。
///
/// 用户口径（2026-10-29 重做合并界面，ADR-101）：「在合并界面中，永远只作为清单被合并，
/// 界面中显示已有的清单，随后将这次合并的内容以不同颜色衔接在这份清单后面」。
///
/// ```
/// 项目已有的清单 1/2                 ← 只读；已完成的保持划线 + 灰
///   ☑ 已经做完的一条
///   ☐ 还没做的一条
/// ── 本次合并新增 2 条 ──────────     ← 用主题色画分隔
///   + 灵感原文甲                     ← 接在清单后面，用主题色
///   + 灵感原文乙
/// ```
///
/// 这一页**不再有可编辑的正文**：合并的产物就是"项目里多出几条待办"，
/// 正文归 AI 整理与正文编辑（旧行为是点「保存」会替换「如何解决」，
/// 用户已明确不要那条路）。所以右上角那个「合并」只把原文按顺序交回去，
/// 真正的落盘由 [applyMergeResultFor] 统一做 —— 界面这一层不直接写数据。
///
/// **落点只能是目标**（Q2）：走到这一页的项目若已经有下级（= 分类），
/// 这一页不给任何合并动作，只说明原因、并把已有清单摆出来 ——
/// 分类只回答"归哪一类"，不装灵感。
class MergeEditorPage extends StatelessWidget {
  /// 单条合并（项目详情页 / 灵感页那条老路）：一条灵感。
  MergeEditorPage({
    super.key,
    required this.project,
    required Inspiration inspiration,
    this.isCategory = false,
  }) : inspirations = <Inspiration>[inspiration];

  /// **多选合并**：一次把选中的多条带进来（Q37）。
  ///
  /// [inspirations] 的顺序**就是**灵感列表上从上到下的顺序，也就是落进清单的
  /// 顺序 —— 一条灵感一条，不拼成一条。
  const MergeEditorPage.many({
    super.key,
    required this.project,
    required this.inspirations,
    this.isCategory = false,
  });

  final Project project;

  /// 这次要并进清单的灵感（至少一条）。
  final List<Inspiration> inspirations;

  /// 这个项目**此刻是不是分类**（有未归档、未删除的直属下级）。
  ///
  /// 分类不装灵感（Q2）：为 `true` 时这一页**不给合并动作**，只说明原因。
  /// 由调用方传 —— 这一页只拿得到一个 `Project` 快照，而"有没有下级"要看整棵树。
  /// 默认 `false` 只覆盖"灵感页那条入口"的历史数据：那条路走 `pickProject`，
  /// 选择器已经把分类挡在外面了。
  final bool isCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    // 这次要并进去的原文，**顺序即列表顺序**（也就是落进清单的顺序）
    final newTexts = <String>[for (final inspiration in inspirations) inspiration.text];

    return Scaffold(
      appBar: AppBar(
        title: Text('合并进「${project.title}」', overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          // 分类不是灵感的落点（Q2）：连动作都不给，这一页只负责说明
          if (!isCategory)
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                MergeResult(itemTexts: newTexts),
              ),
              child: const Text('合并'),
            ),
        ],
      ),
      body: ListView(
        // 整页可滚：窄屏 + 1.6 倍字体下，清单再长也只是往下滚，不会挤爆布局
        //（旧版是 Column + 固定高度折叠面板，条目一多或字体一大就会被顶出去）
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          if (isCategory) ...<Widget>[
            Text(categoryNotForInspiration, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
          ],
          _ExistingChecklist(items: project.items),
          if (!isCategory) ...<Widget>[
            const SizedBox(height: 20),
            _NewItemsHeading(count: newTexts.length),
            for (final text in newTexts)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // 小 + 号：让"这一条是这次要新加进去的"一眼可读
                    Text(
                      '+',
                      style: theme.textTheme.titleMedium?.copyWith(color: primary),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(color: primary),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            Text(
              // 唯一必须留的一句：恢复灵感**不会**把已经写进项目的内容退回去
              '「恢复为待处理」只把灵感放回灵感箱，项目里的内容不会退回。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// 项目**已有的实现清单**（只读）。
///
/// 为什么必须先摆出来：合并只往后追加，按之前得先看得见已经有哪些条目 ——
/// 不然同一个意思并两次，而且没有任何地方提示"已经有了"（用户要的正是
/// "已有清单 + 这次新增接在后面"这一整列）。
///
/// **只读**：打勾、改字、上移下移都在项目详情页。合并这一页再塞一套清单编辑，
/// 用户就分不清自己在动哪一层。
class _ExistingChecklist extends StatelessWidget {
  const _ExistingChecklist({required this.items});

  final List<ProjectItem> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 一条都没有也要给一句：只留空白会被读成"没加载出来"
    if (items.isEmpty) {
      return Text(
        '这个项目还没有清单条目。',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final done = items.where((item) => item.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 进度写进标题：并之前先知道"这个项目已经做了多少"
        Text(
          '项目已有的清单 $done/${items.length}',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 6),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  item.done ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                  size: 16,
                  color: item.done
                      ? theme.colorScheme.outline
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.text,
                    style: item.done
                        ? theme.textTheme.bodyMedium?.copyWith(
                            decoration: TextDecoration.lineThrough,
                            color: theme.colorScheme.outline,
                          )
                        : theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 分隔标题：「从这里往下是这次合并会新增的部分」。
///
/// 整行都用主题色 —— 用户要的"用不同颜色衔接在清单后面"落在这条分隔和
/// 它下面的每一条新增上；已有清单保持正文色，两者一眼分得开。
class _NewItemsHeading extends StatelessWidget {
  const _NewItemsHeading({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Row(
      children: <Widget>[
        Icon(Icons.add, size: 18, color: primary),
        const SizedBox(width: 6),
        // 必须能缩：1.6 倍字体 + 窄屏下这条标题比剩余宽度长时不该把整行顶出去
        Flexible(
          child: Text(
            '本次合并新增 $count 条',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(color: primary),
          ),
        ),
      ],
    );
  }
}

/// 把合并编辑器交回来的结果落到数据上（**单条**：项目详情页那条老路）。
///
/// 与灵感页多选那条路走**同一个** [applyMergeResultFor]，只是带一条灵感进去 ——
/// 两条路的校验与提示因此不可能各说各话。
Future<bool> applyMergeResult(
  BuildContext context,
  AppController app,
  Project project,
  Inspiration inspiration,
  MergeResult result,
) {
  return applyMergeResultFor(
    context,
    app,
    project,
    inspirations: <Inspiration>[inspiration],
    result: result,
  );
}

/// 把合并编辑器交回来的结果落到数据上（**支持多条**，Q37）。
///
/// 这里只负责"挡掉分类 + 给一句提示"；真正的跨文档改动走 `Workspace` 的
/// [Workspace.mergeInspirations]（项目清单追加 + 那些灵感的状态**一次落盘**）。
///
/// **落点只能是目标**（Q2）：这里再挡一道 —— 万一入口那侧没把手上的项目判准
/// （它是快照，看不到"有没有下级"），到了写数据这一步也不会悄悄落进分类。
/// 从前这里还要再挡一次"正文没变"（Q8）；合并只剩清单落点之后，那个判断
/// 连同「保存」那条路一起没了。
///
/// 返回 `true` 表示真的写进去了（灵感页据此决定要不要退出多选）。
Future<bool> applyMergeResultFor(
  BuildContext context,
  AppController app,
  Project project, {
  required List<Inspiration> inspirations,
  required MergeResult result,
}) async {
  if (app.ws.isProjectCategory(project.id)) {
    showToast(context, categoryNotForInspiration, error: true);
    return false;
  }
  final error = app.run(() {
    app.ws.mergeInspirations(
      inspirationIds: <String>[for (final inspiration in inspirations) inspiration.id],
      projectId: project.id,
      itemTexts: result.itemTexts,
    );
  });
  if (!context.mounted) return false;
  if (error != null) {
    showToast(context, error, error: true);
    return false;
  }
  final count = inspirations.length;
  final message = count > 1
      ? '已把 $count 条灵感追加到「${project.title}」的清单，原文可在归档区「已合并」找回'
      : '已追加到「${project.title}」的清单，原文可在归档区「已合并」找回';
  showToast(context, message);
  return true;
}
