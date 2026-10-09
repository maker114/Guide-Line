import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/project_item.dart';
import '../../core/models/task.dart';
import '../events/event_detail_page.dart';
import 'animated_collapse.dart';
import 'color_picker.dart';
import 'dialogs.dart';
import 'due_label.dart';
import 'format.dart';
import 'task_status_button.dart';
import 'urgency.dart';

/// 展开箭头的旋转时长（与事件页、项目页同一个节奏）。
const Duration _tileFoldDuration = Duration(milliseconds: 180);

/// 任务行：**到期 / 全部任务 / 搜索结果**共用。
///
/// 点标题进入所属事件的任务线 —— 任务脱离任务线没有意义，所以不在这里就地编辑。
///
/// 一行里的排布（实机反馈定稿）：
///   ```
///   （✓） 写解析层
///         📈 秋天版本发布              3 天后
///   ```
///   · **完成圆钮在最左**（原先就在这儿；中途挪到右边又被要求挪回来）；
///   · **第一行只有任务名 / 子任务名**：不跟「父任务名 · 子任务」这种尾巴，
///     字号用 `bodyLarge`（比第二行大一档，主次靠字号分开）；
///   · **第二行**：所属事件在左，**到期日（带紧迫度色点）靠右**；
///   · 行尾那颗箭头**只在有待办时出现**（见下）。
///
/// **待办清单就地展开**（2026-10-09，契约 §3.4.2）：待办与任务相互绑定，
/// 所以在"接下来的任务 / 全部任务 / 日历 / 搜索"里也和任务一同出现 ——
/// 从这些页面进事件详情再展开，是四步才够得着一条细则。
///   · 有待办才画箭头；**点箭头只展开、点整行仍然进详情**（各走各的点击区）；
///   · 展开区里点圆形勾选**只勾那一条，不跳页**；
///   · 副标题里那行继承来的日期**留在这里**，展开区里不再重复一遍。
class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.app, required this.task});

  final AppController app;
  final Task task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = app.ws.findEvent(task.eventId);
    final done = task.status == NodeStatus.done;

    // "已搁置"在这里只压**逾期那一档**，不是把整条色阶抹平。
    //
    // 2026-10-01 先改成过"muted ⇒ 一律 `Urgency.none`"，**那是错的**：
    //   · `Tooltip(urgencyLabel(urgency))` 会变成「没有到期日」——
    //     而这条任务明明有到期日，等于对用户说假话；
    //   · `groupByUrgency` 只把 **overdue** 那批切进「未计入逾期」，
    //     muted 线里"3 天后"的任务照样落在「3 天内」组 —— 于是同屏变成
    //     "组头说 3 天内、行里灰点、tooltip 说没有到期日"，
    //     把一处矛盾从「已逾期」档搬到了别的档。
    //
    // 既有口径（照 `event_tab.dart` 那处写）：**只在 `overdue` 时降级**。
    // 于是它与分组、与 `Workspace.overdueTasks`（排除已搁置事件）三边一致：
    // 那条任务不标红、也不再说"没有到期日"。
    final muted = app.ws.isEventMutedForDue(task.eventId);
    final urgency = task.status == NodeStatus.pending
        ? _urgencyForTile(urgencyOf(task.dueAt), muted: muted)
        : Urgency.none;
    final urgencyColor = UrgencyColors.ofContext(context).of(urgency);
    final labelStyle = theme.textTheme.labelSmall;

    // 待办清单（契约 §3.4.2）：**有未勾完的、以及一条都没有的**默认展开 ——
    // 与事件详情页同一条默认规则，状态共用 `app.isExpanded`（显式点过优先）。
    // ⚠️ "一条都没有"落在哪一侧，两处必须一致：任务行这边**不给箭头**
    // （列表里多一个点了没反应的箭头比没有更烦人），所以空清单在这边看不见，
    // 但默认值仍按"展开"算 —— 与详情页同一条规则，省得同一个任务在两页里
    // 一个展开一个收起。
    final checklist = app.ws.taskChecklistOf(task.id);
    final checklistOpen = app.isExpanded(
      'checklist-${task.id}',
      // 与事件详情页**同一条谓词**（空表也算展开）：少写"空表"那一半，
      // 同一个任务就会在两页里一个展开一个收起。
      defaultExpanded: checklist.isEmpty || checklist.any((item) => !item.done),
    );
    // 摘要与事件详情页同一个写法：「待办 d/t」。没有待办就不显示这一项。
    final summary = checklist.isEmpty
        ? null
        : '待办 ${checklist.where((item) => item.done).length}/${checklist.length}';

    final tile = ListTile(
      // 行与行之间收紧（实机反馈：任务之间的间距再小一点）：
      // `dense` 把两行列表的最小高度从 72 降到 64，`compact` 再各轴收 8 ——
      // 文字样式仍由下面显式给（`bodyLarge` / `labelSmall`），不受 `dense` 影响。
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: TaskStatusButton(app: app, task: task),
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              task.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: done
                  ? theme.textTheme.bodyLarge?.copyWith(
                      decoration: TextDecoration.lineThrough,
                      color: theme.colorScheme.outline,
                    )
                  : theme.textTheme.bodyLarge,
            ),
          ),
          // 展开 / 收起待办：**只在有待办时出现**。
          // 这颗按钮有自己的点击区，所以点它不会触发整行的"进事件详情"。
          if (checklist.isNotEmpty)
            IconButton(
              tooltip: checklistOpen ? '收起待办' : '展开待办',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              icon: AnimatedRotation(
                turns: checklistOpen ? 0.5 : 0,
                duration: _tileFoldDuration,
                curve: Curves.easeOutCubic,
                child: const Icon(Icons.expand_more),
              ),
              onPressed: () => app.setExpanded(
                'checklist-${task.id}',
                expanded: !checklistOpen,
              ),
            ),
        ],
      ),
      subtitle: Row(
        children: <Widget>[
          // 左边这一组吃掉剩余宽度（事件名太长时先省略它），
          // 到期日才能稳稳地贴在右边缘
          Expanded(
            child: Row(
              children: <Widget>[
                // 所属事件那颗**标识色小圆点**（与项目树行首同一套标识色系统；
                // 事件没设色时是灰色空心圆）—— 列表里一眼看出这条属于哪条线，
                // 也与日历上那圈圆环的颜色对得上。
                ProjectMarker(color: event?.color, size: 10),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    event?.name ?? '事件已删除',
                    style: labelStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // 「待办 d/t」紧挨着事件名：与事件详情页那行摘要**同一套写法**
          // （`下级 d/t` 那一路也是这么写的）。有空待办才出现。
          if (summary != null) ...<Widget>[
            const SizedBox(width: 8),
            Text(summary, style: labelStyle),
          ],
          const SizedBox(width: 8),
          Tooltip(
            message: urgencyLabel(urgency),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: urgencyColor, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            _dueLabel(context),
            style: labelStyle?.copyWith(color: urgencyColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          ),
        ],
      ),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => EventDetailPage(app: app, eventId: task.eventId),
        ),
      ),
    );

    if (checklist.isEmpty) return tile;

    // 有待办：整行 + 展开区一起返回。**展开区不参与整行的点击** ——
    // 点勾选只勾那一条（用户在这儿勾，正是为了不离开当前页）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        tile,
        AnimatedCollapse(
          expanded: checklistOpen,
          child: Padding(
            padding: const EdgeInsets.only(left: 40, right: 12, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final item in checklist)
                  KeyedSubtree(
                    key: ValueKey<String>('$taskChecklistRowKeyPrefix${item.id}'),
                    child: _TaskChecklistRow(app: app, task: task, item: item),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 这一行该显示哪一档紧迫度。
  ///
  /// 抽成静态纯函数只为一件事：**这条口径只写在一处**。
  /// （不标 `@visibleForTesting`：那是给公开成员用的，而这里刻意是私有的 ——
  /// 不为测试扩大 API。它由 `TaskTile` 的 widget 测试覆盖。）
  static Urgency _urgencyForTile(Urgency raw, {required bool muted}) {
    // 已搁置的事件不再参与到期统计：[Workspace.overdueTasks] 把它排除在
    // 「已逾期」之外、`groupByUrgency` 也照同一份 id 集合切分，所以这里**只压逾期**。
    if (muted && raw == Urgency.overdue) return Urgency.none;
    return raw;
  }

  /// 到期日怎么写：走全应用**唯一出处** `dueLabelOf`（《界面规范》§7）。
  ///
  /// 本行除日期以外还要放事件名与完成钮，所以留给日期的余量按这一行的实际
  /// 占用估（左右外边距约 32、完成圆钮与槽位约 48、色点与间距约 12、
  /// 事件名至少看得见两三个字约 40，再加一点余量）。
  String _dueLabel(BuildContext context) {
    final dueAt = task.dueAt;
    if (dueAt == null || dueAt.isEmpty) return '没排期';
    return dueLabelOf(context, dueAt);
  }
}

/// 展开区里的一行待办：圆形勾选 + 文字。**只在 [TaskTile] 里用**。
///
/// 与事件详情页那一行的差别：这里**不给就地改名**。理由是一条边界 ——
/// 这三个列表页是"扫一遍、勾掉"的地方，改名属于"编辑这件事的内容"，
/// 而任务名本身在这一页也不可改（点行进详情才谈得上编辑，见类文档）。
/// 同一屏里"任务名点了不能改、待办名点了能改"，只会让人误以为任务名也能改。
class _TaskChecklistRow extends StatelessWidget {
  const _TaskChecklistRow({
    required this.app,
    required this.task,
    required this.item,
  });

  final AppController app;
  final Task task;
  final ProjectItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 待办自己没有到期日，**继承宿主任务**：任务逾期即待办逾期，
    // 判据与任务行、逾期横幅同一把尺子（`isTaskRowOverdue`）。
    final overdue = isTaskRowOverdue(
      task.dueAt,
      pending: task.status == NodeStatus.pending,
      muted: app.ws.isEventMutedForDue(task.eventId),
    );

    return InkWell(
      // 点这一行的**其余地方只勾选**：用户在这一页勾待办，正是为了不离开这一页。
      // 想改字就进事件详情（那边点文字即可改）。
      onTap: () {
        final error = app.run(
          () => app.ws.setTaskChecklistItemDone(task.id, item.id, !item.done),
        );
        if (error != null) showToast(context, error, error: true);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: <Widget>[
            // 圆形勾选（与事件详情页、下级清单同一套记号）：未勾是空心圈、
            // 勾上是实心对勾 —— 方形的 `Checkbox` 专属项目自己的清单。
            Icon(
              item.done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 18,
              color: item.done ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: item.done
                    ? theme.textTheme.bodySmall?.copyWith(
                        decoration: TextDecoration.lineThrough,
                        color: theme.colorScheme.outline,
                      )
                    : theme.textTheme.bodySmall?.copyWith(
                        color: overdue ? theme.colorScheme.error : null,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
