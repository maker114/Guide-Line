import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 标识色的候选色板（灵感整理第 10 条）。
///
/// 色值就是用户给的那组 [AccentColors.hexes] —— 低饱和的灰调彩色，
/// 用来在小面积上互相区分，不抢内容。
///
/// 刻意**不做"任意取色"**：项目标识色的用途是"在项目树里一眼认出来"，
/// 一组够区分就够了；放开成任意色反而容易调出彼此难分的近色，
/// 还会让导出文件里出现一堆只差一位的色值。想换风格就换主题，不必逐个项目调色。
const List<String> projectColorChoices = AccentColors.hexes;

/// `#rrggbb` → `Color`；解析不了返回 `null`（与 `Canonical.normalizeHexColor` 同一口径）。
Color? colorOfHex(String? hex) {
  final text = hex?.trim().replaceFirst('#', '');
  if (text == null || text.length != 6) return null;
  final value = int.tryParse(text, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

/// 项目标识的**统一视觉线索**：
///   · 有标识色 → **实心圆**（不加任何描边）；
///   · 没有标识色 → **灰色空心圆**（一眼看出"这个还没分配颜色"）。
///
/// 两处都按实机反馈改过：原来有颜色时也描一圈浅灰边，看着像"空心带填充"，
/// 浅色主题下那圈边还抢了实心圆的边界；未设置时又回落到一个文件夹图标，
/// 与已设置的圆点不是一套形状，扫一列下来参差不齐。
///
/// 之所以收成一个控件：项目树、灵感列表、分配灵感的选择器都要显示它，
/// 三处各写一遍迟早出现"树上是实心圆、选择器里是图标"的不一致。
class ProjectMarker extends StatelessWidget {
  const ProjectMarker({super.key, required this.color, this.size = 18});

  /// 项目的标识色（`#rrggbb`），`null` 表示未设置 → 灰色空心圆
  final String? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolved = colorOfHex(color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // 有颜色：实心填充、无描边。没颜色：不填充、用灰描边画个空心圆。
        color: resolved,
        shape: BoxShape.circle,
        border: resolved == null
            ? Border.all(color: theme.colorScheme.outline, width: 1.5)
            : null,
      ),
    );
  }
}

/// 选标识色。返回：
///   · `null` —— 用户取消（保持原值）；
///   · `''`   —— 用户选择"不用标识色"，调用方据此清空。
Future<String?> pickProjectColor(BuildContext context, {String? current}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('项目标识色', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                '只在项目树与标题旁显示，不影响状态与完成判定。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  for (final hex in projectColorChoices)
                    _Swatch(
                      hex: hex,
                      selected: current == hex,
                      onTap: () => Navigator.of(sheetContext).pop(hex),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(sheetContext).pop(''),
                  icon: const Icon(Icons.format_color_reset_outlined),
                  label: const Text('不用标识色'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.hex, required this.selected, required this.onTap});

  final String hex;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorOfHex(hex),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? theme.colorScheme.onSurface : theme.colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}
