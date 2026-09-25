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
///   · **第一行**：任务名（`bodyLarge`，这一行的主角）+ **靠右的到期日**
///     （带紧迫度色点）+ **最右的完成圆钮**（原来在最左边）；
///   · **第二行**：所属事件（`labelSmall`，小一号的次要信息）。
///     名字比它大一号 —— 主次一眼分得开；
///   · 任务名那一行**只有名字**：不再跟「父任务名 · 子任务」这种尾巴
///     （整行尾巴一律去掉，扫一列就是一张干净的任务清单）；
///   · **没有箭头**：整行本来就点得进去。
///
/// 为什么自己排而不用 `ListTile`：右对齐要求"任务名吃掉剩余宽度、右边的
/// 日期不伸缩"。`ListTile` 给 `trailing` 的约束与它自己的最小宽度会打架
/// （实测 1.6 倍字体下 RenderFlex 溢出），而 `Row` + `Expanded`
/// 正好是这条语义，一行就能写清楚。
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

    return InkWell(
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => EventDetailPage(app: app, eventId: task.eventId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            LayoutBuilder(
              builder: (context, constraints) => Row(
                children: <Widget>[
                  // 任务名：这一行的主角，字号比下面那行大一档
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
                  const SizedBox(width: 8),
                  // 右边：紧迫度色点 + 到期日（**不伸缩** → 与任务名同一行、贴右）
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
                    _dueLabel(context, constraints.maxWidth),
                    style: labelStyle?.copyWith(color: urgencyColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                  TaskStatusButton(app: app, task: task),
                ],
              ),
            ),
            // 第二行：所属事件。**只留事件名** —— 父任务名与「子任务」标签
            // 都不再往这一行上挂（实机反馈：那一串是噪声）
            Padding(
              padding: const EdgeInsets.only(top: 2),
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
          ],
        ),
      ),
    );
  }

  /// 到期日怎么写：**默认「绝对日期 + 剩余天数」**（设计文档的统一口径），
  /// 但这一行还要放任务名与完成钮，大字体下那串绝对日期根本塞不下（实测
  /// 1.6 倍字体、360dp 宽时它一个人就要 240dp，会把任务名挤成两个字）。
  ///
  /// 所以按**实际可用宽度**选：放得下用全称，放不下退成「3 天后」——
  /// 两个写法都带着"还剩几天"，不会把最有用的信息丢掉。
  String _dueLabel(BuildContext context, double rowWidth) {
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
    if (widthOf(full) + _reservedWidthForTitle <= rowWidth) return full;
    return describeDate(dueAt);
  }

  /// 留给"任务名 + 完成圆钮"的宽度：圆钮约 40、色点与间距约 12，
  /// 再加上任务名至少看得见四五个字 —— 宁可把日期退成简称，
  /// 也别把任务名挤到只剩两个字。
  static const double _reservedWidthForTitle = 150;
}
