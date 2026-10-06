import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 时间选择器：**12 格表盘 + 上午/下午，下午那半圈按 24 小时标**（用户 2026-10-06）。
///
/// ## 为什么自己画，而不是用 `showTimePicker`
///
/// 试过三版，结论钉在这里（也写在 `due_sheet.dart` 与 CHANGELOG 2.7.10）：
///
/// 1. 只换 `MaterialLocalizations` ⇒ 只有**表头**变 24 小时。因为 12 格模式下
///    SDK 把**格位**（1–12）交给 `formatHour`（`time_picker.dart:1563`），
///    它手里**没有"15"这个数**，标不出 13–23。
/// 2. 再加 `alwaysUse24HourFormat: true` ⇒ 表盘标 0–23，但几何变**两圈**、
///    且**上午/下午开关消失**（用户明确不要这个）。
/// 3. 要"12 格 + 下午标 13–23 + 保留上午/下午"，只能自己画 —— 就是这个文件。
///
/// ## 口径
///
/// - **上午**：12 点方向是 `12`、顺时针 `1`–`11`（与系统表盘一致）；
///   12 点方向那一格代表 **00:00**（午夜）。
/// - **下午**：同一格标 `12`（正午）、顺时针 `13`–`23`。
/// - **分钟**：12 格、每格 5 分钟（`00 05 … 55`）—— 用户口径"只需要 5 分钟就行了"，
///   与系统表盘自己的步长一致。
/// - 先选小时（选完自动进分钟），再选分钟（选完即完成）；中途可点「上午 / 下午」换半天。
Future<TimeOfDay?> showPm24TimePicker(
  BuildContext context, {
  required TimeOfDay initial,
}) {
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _Pm24TimePicker(initial: initial),
  );
}

/// 12 个格位里的第 [index] 格（0 是 12 点方向，顺时针 1..11）代表几点。
///
/// **纯函数**，由 `test/ui/pm24_picker_test.dart` 钉住 —— 表盘的命中与标字
/// 都走它，所以它是这一页唯一需要机器验证的逻辑。
int hourForDialIndex(int index, {required bool pm}) {
  if (index == 0) return pm ? 12 : 0; // 12 点方向：正午 / 午夜
  return pm ? index + 12 : index; // 1..11 → 13..23 / 1..11
}

/// 那一格上写什么字。
String labelForDialIndex(int index, {required bool pm}) {
  if (index == 0) return '12';
  return '${pm ? index + 12 : index}';
}

/// 分钟格的命中的第 [index] 格代表几分（每格 5 分钟）。
int minuteForDialIndex(int index) => (index % 12) * 5;

String _two(int v) => v.toString().padLeft(2, '0');

class _Pm24TimePicker extends StatefulWidget {
  const _Pm24TimePicker({required this.initial});

  final TimeOfDay initial;

  @override
  State<_Pm24TimePicker> createState() => _Pm24TimePickerState();
}

class _Pm24TimePickerState extends State<_Pm24TimePicker> {
  late int _hour;
  late int _minute;
  late bool _pm;
  bool _minuteMode = false;

  @override
  void initState() {
    super.initState();
    _hour = widget.initial.hour;
    // 落到 5 分钟那一格上（系统表盘也是 5 分钟一格）
    _minute = (widget.initial.minute ~/ 5) * 5;
    _pm = widget.initial.hour >= 12;
  }

  int get _dialIndex {
    if (_minuteMode) return (_minute ~/ 5) % 12;
    final int h12 = _hour % 12; // 0..11，0 就是 12 点方向
    return h12;
  }

  void _pickDialIndex(int index) {
    setState(() {
      if (_minuteMode) {
        _minute = minuteForDialIndex(index);
      } else {
        _hour = hourForDialIndex(index, pm: _pm);
        _minuteMode = true; // 选完小时自动进分钟，和系统表盘一个节奏
      }
    });
  }

  void _setPm(bool pm) {
    if (pm == _pm) return;
    setState(() {
      _pm = pm;
      // 半天换了，小时跟着走：12 小时那一半的读数保持不变
      final int h12 = _hour % 12;
      _hour = pm ? (h12 == 0 ? 12 : h12 + 12) : h12;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final labels = <String>[
      for (int i = 0; i < 12; i++)
        _minuteMode ? _two(minuteForDialIndex(i)) : labelForDialIndex(i, pm: _pm),
    ];

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: <Widget>[
                  // 表头按 24 小时写（用户认可的那半）
                  Text(
                    '${_two(_hour)}:${_two(_minute)}',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _minuteMode ? '选分钟' : '选小时',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 268,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final Size size = context.size ?? const Size(268, 268);
                  setState(() => _pickDialIndex(_indexFor(
                        details.localPosition,
                        Size(size.width, 268),
                      )));
                },
                child: CustomPaint(
                  painter: _DialPainter(
                    labels: labels,
                    selectedIndex: _dialIndex,
                    ring: scheme.surfaceContainerHighest,
                    label: scheme.onSurfaceVariant,
                    selectedFill: scheme.primary,
                    selectedLabel: scheme.onPrimary,
                    style: theme.textTheme.bodyMedium,
                    textScaler: MediaQuery.textScalerOf(context),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Row(
                children: <Widget>[
                  _HalfToggle(
                    label: '上午',
                    selected: !_pm,
                    onTap: () => _setPm(false),
                  ),
                  const SizedBox(width: 8),
                  _HalfToggle(
                    label: '下午',
                    selected: _pm,
                    onTap: () => _setPm(true),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      TimeOfDay(hour: _hour, minute: _minute),
                    ),
                    child: const Text('完成'),
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

/// 点在哪一格上：把触点转成"12 点方向为 0、顺时针 +1"的格号。
///
/// 抽成静态方法是为了能单测（角度 → 格号是这一页最容易错的一步）。
int _indexFor(Offset local, Size size) {
  final Offset center = Offset(size.width / 2, size.height / 2);
  final Offset v = local - center;
  final double deg = (math.atan2(v.dy, v.dx) * 180 / math.pi + 90 + 360) % 360;
  return ((deg + 15) ~/ 30) % 12;
}

class _HalfToggle extends StatelessWidget {
  const _HalfToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerHighest,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.labels,
    required this.selectedIndex,
    required this.ring,
    required this.label,
    required this.selectedFill,
    required this.selectedLabel,
    required this.style,
    required this.textScaler,
  });

  final List<String> labels;
  final int selectedIndex;
  final Color ring;
  final Color label;
  final Color selectedFill;
  final Color selectedLabel;
  final TextStyle? style;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = size.shortestSide / 2 - 30;
    final double cell = 38;

    for (int i = 0; i < 12; i++) {
      final double angle = -math.pi / 2 + i * math.pi / 6;
      final Offset at = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      final bool on = i == selectedIndex;

      canvas.drawCircle(
        at,
        cell / 2,
        Paint()..color = on ? selectedFill : ring,
      );

      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: (style ?? const TextStyle()).copyWith(
            color: on ? selectedLabel : label,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) =>
      old.selectedIndex != selectedIndex ||
      old.labels.join() != labels.join() ||
      old.ring != ring ||
      old.selectedFill != selectedFill;
}
