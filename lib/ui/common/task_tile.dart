import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/enums.dart';
import '../../core/models/task.dart';
import '../events/event_detail_page.dart';
import 'format.dart';
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

    // 已完成 / 已搁置的任务不再"报警"，一律走灰
    final urgency = task.status == NodeStatus.pending ? urgencyOf(task.dueAt) : Urgency.none;
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
                const Icon(Icons.timeline, size: 13),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    event?.name ?? '（事件已删除）',
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

  /// 到期日怎么写：**默认「绝对日期 + 剩余天数」**（设计文档的统一口径），
  /// 但这一行还要放事件名与完成钮，大字体下那串绝对日期根本塞不下（实测
  /// 1.6 倍字体、360dp 宽时它一个人就要 240dp，会把事件名挤没）。
  ///
  /// 所以按**屏幕宽度**选：放得下用全称，放不下退成「3 天后」——
  /// 两个写法都带着"还剩几天"，不会把最有用的信息丢掉。
  ///
  /// 用屏幕宽度而不是 `LayoutBuilder`：`ListTile` 在**量高度**时给副标题的
  /// `maxWidth` 是 `Infinity`（同页其它地方踩过这个坑），那里量不出真实宽度。
  String _dueLabel(BuildContext context) {
    final dueAt = task.dueAt;
    if (dueAt == null || dueAt.isEmpty) return '没排期';

    final style = Theme.of(context).textTheme.labelSmall ?? const TextStyle();
    final scaler = MediaQuery.textScalerOf(context);
    double widthOf(String text) => (TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout())
            .width;

    final full = describeDateWithDays(dueAt);
    final screenWidth = MediaQuery.sizeOf(context).width;
    if (widthOf(full) + _reservedWidth <= screenWidth) return full;
    return describeDate(dueAt);
  }

  /// 一行里除日期以外**必须占掉**的宽度（估宽一点）：
  /// 左右外边距约 32、完成圆钮与它的槽位约 48、色点与间距约 12、
  /// 事件名至少看得见两三个字约 40，再加一点余量。
  static const double _reservedWidth = 200;
}
