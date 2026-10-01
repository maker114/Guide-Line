import 'package:flutter/material.dart';

/// 点阵屏上的一排：一个短码 + 它的语义标签。
///
/// [semanticsLabel] 是**给读屏软件**的整句（例如"云端提交码 a1b2c3d"）。
/// [sha] 只放前 7 位十六进制 —— 这与 [shortSha] 的位数一致，
/// **调用方必须自己先收口**，别把完整 sha 递进来（那会让读屏软件念 40 个字符）。
class CommitLcdRow {
  const CommitLcdRow({required this.sha, required this.semanticsLabel});

  /// 短码（前 7 位十六进制）。空串 = 这一排整排暗着。
  final String sha;

  /// 读屏软件念的那句话。
  final String semanticsLabel;
}

/// 提交号的 **LCD 点阵屏**（每排 7 格，每格 7×9 点）。
///
/// 为什么用点阵而不是普通文字：这一格回答的是"我现在跟着的是哪一次上传"，
/// 七位十六进制码本来就没有语义、只能逐位比 —— 点阵比字体更像"设备上读出来的号"，
/// 一眼扫过去就能和 GitHub 页面上那串对上，不用逐字辨认字体形状。
///
/// 四条口径（2026-09-30 定）：
///   · **没有提交号就全暗**，不写"未知"之类的字 —— 一块熄着的屏，比一行假文字诚实；
///   · 亮/暗是同一种色的**深浅两档**（不是黑底绿字的自定义配色），
///     所以它跟着主题走，浅色深色都不会出现"看不见的点"；
///   · 每格 **7×9** 点（8×16 摆在真机上太高，一路收到 7×12、再收三行到 7×9）；
///     字形 5×7 一点没动，减掉的全是四周的留白；
///   · 外壳就是一张**普通卡片**（`AppShapes.card` 的圆角 + `elevation: 1`，与灵感页那张
///     速记卡片同一档），不另配色。原来那版是"浅灰底 + 细描边 + 圆角 10"，
///     摆在卡片流里像另一个软件里的零件。
///
/// 2026-10-02 改成**多排**：GitHub 页要并排摆"云端"与"本机"两个码，
/// 所以里层从"一排"变成"若干排竖向叠放"，每排的语义各说各的。
/// 一排仍然是 7 格 —— 与 [shortSha] 的位数一致，**两处都得是 7，否则对不上号**。
class CommitLcd extends StatelessWidget {
  const CommitLcd({super.key, required this.rows, this.cellCount = 7});

  /// 从上到下的若干排。
  final List<CommitLcdRow> rows;

  /// 每排的格数。默认 7 —— 与 `shortSha` 的位数一致，两处都得是 7，否则对不上号。
  final int cellCount;

  /// 每格的列数（宽）。
  static const int cellWidth = 7;

  /// 每格的行数（高）。
  static const int cellHeight = 9;

  /// 格与格之间空一列，点才不会连成一片。
  static const int cellGap = 1;

  /// 排与排之间的间距（px）。
  static const double rowGap = 10;

  /// 一行点阵的总列数（画家据此把宽度换算成点的大小）。
  static int columnsFor(int cellCount) =>
      cellCount * cellWidth + (cellCount - 1) * cellGap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = <Widget>[];
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final sha = row.sha.trim();
      final chars = List<String>.generate(
        cellCount,
        (i) => i < sha.length ? sha[i] : ' ',
      );
      if (index > 0) lines.add(const SizedBox(height: rowGap));
      lines.add(
        Semantics(
          // 点阵对读屏软件等于空白：这一排是什么意思，只能靠这句话说。
          label: row.semanticsLabel,
          // **两排必须各是一个语义节点**（2026-10-02 实测定下来）。
          // 不加这一行时，Column 会把两排的 label 用换行拼成一个节点，
          // 读屏软件连成一句念："云端提交码 a1b2c3d 本机内容码 9f8e7d6" ——
          // 两句糊在一起就分不出哪个是云端哪个是本机了。
          explicitChildNodes: true,
          container: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dot = constraints.maxWidth / columnsFor(cellCount);
              return SizedBox(
                height: dot * cellHeight,
                width: constraints.maxWidth,
                child: CustomPaint(
                  painter: CommitLcdPainter(
                    chars: chars,
                    // 深浅两档取自同一支色：亮 = 主色，暗 = 极淡的主色
                    lit: scheme.primary,
                    dim: scheme.primary.withValues(alpha: 0.08),
                  ),
                ),
              );
            },
          ),
        ),
      );
    }
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(children: lines),
      ),
    );
  }
}

/// 点阵的画家：把每个字符按 [CommitLcdGlyphs] 里的 5×7 点阵铺进 7×10 的格子里。
class CommitLcdPainter extends CustomPainter {
  const CommitLcdPainter({
    required this.chars,
    required this.lit,
    required this.dim,
  });

  final List<String> chars;
  final Color lit;
  final Color dim;

  @override
  void paint(Canvas canvas, Size size) {
    final columns = CommitLcd.columnsFor(chars.length);
    final dot = size.width / columns;
    final side = dot * 0.78;
    final paint = Paint()..style = PaintingStyle.fill;
    final radius = Radius.circular(side * 0.22);

    for (var index = 0; index < chars.length; index++) {
      final rows = CommitLcdGlyphs.of(chars[index]);
      final baseX = index * (CommitLcd.cellWidth + CommitLcd.cellGap) * dot;
      for (var row = 0; row < CommitLcd.cellHeight; row++) {
        for (var col = 0; col < CommitLcd.cellWidth; col++) {
          paint.color = _isLit(rows, row, col) ? lit : dim;
          final left = baseX + col * dot + (dot - side) / 2;
          final top = row * dot + (dot - side) / 2;
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(left, top, side, side), radius),
            paint,
          );
        }
      }
    }
  }

  /// 这一格点不点亮：把字符的点阵贴进格子的正中（7×10 里放 5×7 → 左右各留一列、
  /// 上下留白），贴不上的位置一律是暗点 —— 于是"没有号"就是一块整屏的暗点。
  static bool _isLit(List<int>? rows, int row, int col) {
    if (rows == null) return false;
    final y = row - CommitLcdGlyphs.offsetY;
    final x = col - CommitLcdGlyphs.offsetX;
    if (y < 0 || y >= rows.length) return false;
    if (x < 0 || x >= CommitLcdGlyphs.glyphWidth) return false;
    return (rows[y] >> (CommitLcdGlyphs.glyphWidth - 1 - x)) & 1 == 1;
  }

  @override
  bool shouldRepaint(CommitLcdPainter old) =>
      old.lit != lit || old.dim != dim || !_same(old.chars, chars);

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 十六进制字符的 5×7 点阵（每行 5 位，最高位是最左边那一列）。
///
/// 只收 0-9 / a-f：提交码就是这十六个字符，别的字符画不出来就整格不亮 ——
/// 与其为不可能出现的字符编一套字形，不如让它"亮不起来"，一眼能看出不对。
abstract final class CommitLcdGlyphs {
  static const int glyphWidth = 5;

  /// 5 宽的图形放进 7 宽的格子里，左右各留 1 列。
  static const int offsetX = 1;

  /// 7 行放进 9 行里：上下各留 1 行（再少一行就要削字形了）。
  static const int offsetY = 1;

  static List<int>? of(String char) => _glyphs[char.toLowerCase()];

  static const Map<String, List<int>> _glyphs = <String, List<int>>{
    '0': <int>[0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
    '1': <int>[0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    '2': <int>[0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
    '3': <int>[0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
    '4': <int>[0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
    '5': <int>[0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
    '6': <int>[0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
    '7': <int>[0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    '8': <int>[0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
    '9': <int>[0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    'a': <int>[0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F],
    'b': <int>[0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x1E],
    'c': <int>[0x00, 0x00, 0x0F, 0x10, 0x10, 0x10, 0x0F],
    'd': <int>[0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x0F],
    'e': <int>[0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E],
    'f': <int>[0x06, 0x09, 0x08, 0x1C, 0x08, 0x08, 0x08],
  };
}
