import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 标识色的候选色板。
///
/// 色值就是 [AccentColors.hexes]（唯一来源是 core 的 `ProjectPalette`）——
/// 低饱和的灰调彩色，用来在小面积上互相区分，不抢内容。
/// 2026-09-26 从 12 支加到 **16 支**（补靛蓝 / 橄榄 / 咖棕 / 青灰四段色相），
/// 挑选口径与可辨距离写在 `lib/core/models/project_palette.dart` 的注释里，
/// 由 `test/core/project_palette_test.dart` 守着。
///
/// 刻意**不做"任意取色"**：项目标识色的用途是"在项目树里一眼认出来"，
/// 一组够区分就够了；放开成任意色反而容易调出彼此难分的近色，
/// 还会让导出文件里出现一堆只差一位的色值。想换风格就换主题，不必逐个项目调色。
const List<String> projectColorChoices = AccentColors.hexes;

/// 取色方阵**固定 4 列**（16 支色 = 4 列 × 4 行）。
///
/// 为什么不跟随屏宽自动折行：格数一多，"哪一支是刚才那支"就找不到北了 ——
/// 4 × 4 的方阵在哪种屏宽下都长一个样，用户第二次进来还认得位置。
const int _swatchColumns = 4;

/// 色块之间的间隔（横竖同值）。
const double _swatchGap = 12;

/// 单个色块的 Key：用例靠它数"4 列 × 4 行"、并点中某一支。
@visibleForTesting
Key colorSwatchKey(String hex) => Key('ColorPicker.swatch.$hex');

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

/// 项目标识色的**竖条**（项目树行首、项目详情页标题旁共用）。
///
/// 与 [ProjectMarker] 是同一个信息的两种形状：圆点用在"一列项目里认人"，
/// 竖条用在"标题旁边立一个标记"—— 标题是横着读的，左边立一根竖条比一个圆点
/// 更贴边、也更像"这一页属于这个颜色"。
///
/// **没设色时用中性灰补齐同一个位置**（实机反馈）：空着会让标题一列一个位置。
class ProjectColorBar extends StatelessWidget {
  const ProjectColorBar({
    super.key,
    required this.color,
    this.width = 4,
    this.height = 16,
  });

  /// 项目的标识色（`#rrggbb`），`null` → 中性灰
  final String? color;
  final double width;
  final double height;

  /// 两端圆角半径
  static const double _barRadius = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colorOfHex(color) ?? theme.colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(_barRadius),
      ),
    );
  }
}

/// 选标识色。返回：
///   · `null` —— 用户取消（保持原值）；
///   · `''`   —— 用户选择"不用标识色"，调用方据此清空。
Future<String?> pickProjectColor(BuildContext context, {String? current}) {
  return _pickMarkerColor(
    context,
    current: current,
    title: '项目标识色',
    hint: '显示在项目树与标题旁',
  );
}

/// 事件的标识色（与项目同一套色板与口径）。
Future<String?> pickEventColor(BuildContext context, {String? current}) {
  return _pickMarkerColor(
    context,
    current: current,
    title: '事件标识色',
    hint: '任务列表里的小圆点与日历上的圆环都用它',
  );
}

/// 取色面板的**唯一实现**（项目 / 事件共用，只有标题与说明不同）。
Future<String?> _pickMarkerColor(
  BuildContext context, {
  required String title,
  required String hint,
  String? current,
}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return SafeArea(
        // 面板内容**可以滚**：窄屏 + 1.6 倍字体下 4 行色块加标题会顶到
        // 底部面板的高度上限，不滚就是一条溢出报错（批 B 第 ② 项）。
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(hint, style: theme.textTheme.bodySmall),
                const SizedBox(height: 14),
                ..._swatchGrid(
                  current: current,
                  onPick: (hex) => Navigator.of(sheetContext).pop(hex),
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
        ),
      );
    },
  );
}

/// 把色板排成 **4 列 × 4 行**（最后一行不满 4 个时也不拉伸、不居中）。
///
/// 每行自己是一个 `Row`，而不是 `Wrap` / `GridView`：
///   · `Wrap` 的每行格数跟屏宽走，平板上一行能塞 6 个，"4 × 4"就不成立了；
///   · `GridView` 会把格子约束成"等分宽度"，40dp 的圆会被拉到几十 dp 大。
/// 固定尺寸的 `Row` 是唯一能同时钉住"列数"和"圆的大小"的写法。
Iterable<Widget> _swatchGrid({
  required String? current,
  required void Function(String hex) onPick,
}) {
  final rows = <Widget>[];
  final hexes = projectColorChoices;
  for (var start = 0; start < hexes.length; start += _swatchColumns) {
    final row = hexes.skip(start).take(_swatchColumns).toList(growable: false);
    rows.add(
      Padding(
        padding: EdgeInsets.only(top: start == 0 ? 0 : _swatchGap),
        child: Row(
          children: <Widget>[
            for (var i = 0; i < row.length; i += 1)
              Padding(
                padding: EdgeInsets.only(
                  right: i == row.length - 1 ? 0 : _swatchGap,
                ),
                child: _Swatch(
                  key: colorSwatchKey(row[i]),
                  hex: row[i],
                  selected: current == row[i],
                  onTap: () => onPick(row[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
  return rows;
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.hex,
    required this.selected,
    required this.onTap,
  });

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
