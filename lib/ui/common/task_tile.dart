import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import '../events/event_detail_page.dart';
import 'color_picker.dart';
import 'due_label.dart';
import 'task_status_button.dart';
import 'urgency.dart';

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
///   · **没有箭头**：整行本来就点得进去。
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

    return ListTile(
      // 行与行之间收紧（实机反馈：任务之间的间距再小一点）：
      // `dense` 把两行列表的最小高度从 72 降到 64，`compact` 再各轴收 8 ——
      // 文字样式仍由下面显式给（`bodyLarge` / `labelSmall`），不受 `dense` 影响。
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: TaskStatusButton(app: app, task: task),
      title: Text(
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
