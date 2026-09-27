import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ids.dart';
import '../../core/models/task.dart';
import '../common/color_picker.dart';
import '../common/format.dart';
import '../common/task_tile.dart';
import '../theme/shape_tokens.dart';
import 'task_grouping.dart';

/// 「接下来的任务」的**任务日历**：按月看哪几天有任务、分别属于哪条线。
///
/// 每个有任务的日期，数字外面画一圈**圆环**，颜色就是任务所属事件的标识色；
/// 一天里有几条任务，圆环就分成几段等长的弧（两条各占一半，三条各占三分之一……）。
/// 点一天，下面列出那天的任务。
///
/// 口径与列表页一致：只算**还开着的**任务（`Workspace.openTasks()`），
/// 也就是已搁置 / 已完成的不会出现在日历上。
class TaskCalendarPage extends StatefulWidget {
  const TaskCalendarPage({super.key, required this.app});

  final AppController app;

  @override
  State<TaskCalendarPage> createState() => _TaskCalendarPageState();
}

class _TaskCalendarPageState extends State<TaskCalendarPage> {
  /// 当前显示的月份（只用到年 / 月，固定取 1 号）
  late DateTime _month;

  /// 用户手动点选的日期（`YYYY-MM-DD`）；**没点过就是 `null`**。
  ///
  /// 不缓存"今天"（Q-10）：原来初值写死 `todayDateString()`，页面停在后台跨过午夜之后
  /// 仍然高亮昨天，而 `isToday` 是现算的 —— 同一屏上两个"今天"对不上。
  /// 现在往下取的是 [selected]，没点过时每次现算。
  String? _pickedDate;

  /// 选中的日期：没手动点过就是"此刻的今天"。
  String get _selected => _pickedDate ?? todayDateString();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final tasks = widget.app.ws.openTasks();
        final marks = taskMarksByDate(
          tasks,
          (task) => widget.app.ws.findEvent(task.eventId)?.color,
          theme.colorScheme.outlineVariant,
        );
        final selectedTasks = tasksOn(_selected, tasks);
        final undated = tasks.where((t) => t.dueAt == null || t.dueAt!.isEmpty).length;

        return Scaffold(
          appBar: AppBar(title: const Text('日历')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: <Widget>[
              _MonthBar(
                month: _month,
                onPrevious: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                onNext: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
                onToday: () => setState(() {
                  final now = DateTime.now();
                  _month = DateTime(now.year, now.month);
                  _pickedDate = todayDateString();
                }),
              ),
              const _WeekdayHeader(),
              _MonthGrid(
                month: _month,
                marks: marks,
                selected: _selected,
                onSelect: (date) => setState(() => _pickedDate = date),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${monthDayLabel(_selected)}'
                        '${selectedTasks.isEmpty ? '' : ' · ${selectedTasks.length} 条'}',
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    if (undated > 0)
                      Text('另有 $undated 条没排期', style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
              if (selectedTasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text('这一天没有排期的任务', style: theme.textTheme.bodySmall),
                )
              else
                for (final task in selectedTasks)
                  Column(
                    children: <Widget>[
                      TaskTile(app: widget.app, task: task),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// 日期 → 这一天各条任务的标记色（**一条任务一段弧**）。
///
/// 颜色取任务所属事件的标识色（[colorHexOf] 返回 `#rrggbb`），
/// 事件没设色就用 [fallback]（中性灰）。
///
/// **纯函数**，所以"一天里两条任务 = 两段弧、三条 = 三段"这类规则能直接单测。
Map<String, List<Color>> taskMarksByDate(
  List<Task> tasks,
  String? Function(Task task) colorHexOf,
  Color fallback,
) {
  final marks = <String, List<Color>>{};
  for (final task in tasks) {
    final due = task.dueAt;
    if (due == null || due.isEmpty) continue;
    marks.putIfAbsent(due, () => <Color>[]).add(colorOfHex(colorHexOf(task)) ?? fallback);
  }
  return marks;
}

/// 今天（`YYYY-MM-DD`）。
String todayDateString() => Ids.todayDate();

/// 某天的任务（按任务顺序排好）。
List<Task> tasksOn(String date, List<Task> tasks) =>
    tasks.where((task) => task.dueAt == date).toList()
      ..sort(byOrderOfTask);

/// 日期文案：`2026-09-28` → `9 月 28 日`。
String monthDayLabel(String date) {
  final parsed = parseIsoDate(date);
  if (parsed == null) return date;
  return '${parsed.month} 月 ${parsed.day} 日';
}

/// 日历格子的 Key（用例靠它点某一天）。
@visibleForTesting
Key calendarDayKey(String date) => Key('TaskCalendar.day.$date');

/// 月份切换条：`‹ 2026 年 9 月 ›` 加一个「今天」。
class _MonthBar extends StatelessWidget {
  const _MonthBar({
    required this.month,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  final DateTime month;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: '上个月',
            icon: const Icon(Icons.chevron_left),
            onPressed: onPrevious,
          ),
          Expanded(
            child: Text(
              '${month.year} 年 ${month.month} 月',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton(onPressed: onToday, child: const Text('今天')),
          IconButton(
            tooltip: '下个月',
            icon: const Icon(Icons.chevron_right),
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  static const List<String> _labels = <String>['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: <Widget>[
          for (final label in _labels)
            Expanded(
              child: Text(label, textAlign: TextAlign.center, style: style),
            ),
        ],
      ),
    );
  }
}

/// 一个月的格子：周一开头，每行 7 天。
class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.marks,
    required this.selected,
    required this.onSelect,
  });

  final DateTime month;
  final Map<String, List<Color>> marks;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    // 周一 = 0（`DateTime.monday == 1`）
    final leading = (first.weekday - DateTime.monday) % 7;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final today = todayDateString();

    final cells = <Widget>[
      for (var i = 0; i < leading; i += 1) const SizedBox.shrink(),
      for (var day = 1; day <= daysInMonth; day += 1)
        _DayCell(
          date: Ids.todayDate(DateTime(month.year, month.month, day)),
          day: day,
          colors: marks[Ids.todayDate(DateTime(month.year, month.month, day))] ?? const <Color>[],
          selected: Ids.todayDate(DateTime(month.year, month.month, day)) == selected,
          isToday: Ids.todayDate(DateTime(month.year, month.month, day)) == today,
          onTap: onSelect,
        ),
    ];

    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(
        Row(
          children: <Widget>[
            for (var j = 0; j < 7; j += 1)
              Expanded(
                child: i + j < cells.length ? cells[i + j] : const SizedBox.shrink(),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(children: rows),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.day,
    required this.colors,
    required this.selected,
    required this.isToday,
    required this.onTap,
  });

  final String date;
  final int day;
  final List<Color> colors;
  final bool selected;
  final bool isToday;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: calendarDayKey(date),
      onTap: () => onTap(date),
      borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
      child: SizedBox(
        height: 46,
        child: Center(
          child: DayRing(
            colors: colors,
            selected: selected,
            child: Text(
              '$day',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isToday ? theme.colorScheme.primary : null,
                fontWeight: isToday ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 日期外面那圈**按事件色分段**的圆环。
///
/// 一条任务一段弧：两条各占一半、三条各占三分之一……颜色全部相同（同一事件
/// 两条任务）时看起来就是一个实心环，这也是对的 —— 它表达的是"这一天有两条"。
class DayRing extends StatelessWidget {
  const DayRing({
    super.key,
    required this.colors,
    required this.selected,
    required this.child,
  });

  final List<Color> colors;
  final bool selected;
  final Widget child;

  /// 圆环直径与线宽（格子高度按它来定）。
  static const double size = 38;
  static const double strokeWidth = 3;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: DayRingPainter(colors: colors, strokeWidth: strokeWidth),
        child: Center(
          child: Container(
            width: size - strokeWidth * 2 - 2,
            height: size - strokeWidth * 2 - 2,
            alignment: Alignment.center,
            decoration: selected
                ? BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  )
                : null,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 把 [colors] 等分成弧画一圈（从 12 点方向顺时针）。
class DayRingPainter extends CustomPainter {
  const DayRingPainter({required this.colors, required this.strokeWidth});

  final List<Color> colors;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.width / 2 - strokeWidth / 2,
    );
    final sweep = 2 * math.pi / colors.length;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    for (var i = 0; i < colors.length; i += 1) {
      paint.color = colors[i];
      // -π/2 = 12 点方向；每段之间**不留缝**（缝会让人以为是一天里的两个间断）
      canvas.drawArc(rect, -math.pi / 2 + i * sweep, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(DayRingPainter oldDelegate) =>
      oldDelegate.strokeWidth != strokeWidth || !_sameColors(oldDelegate.colors, colors);

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
