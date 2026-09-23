// 生成 Android 启动图标（`android/app/src/main/res/mipmap-*/ic_launcher.png`）。
//
// 为什么是脚本而不是一张设计好的 PNG：仓库里不引入图形依赖，也不希望"图是怎么来的"
// 只存在于某台机器上。图形本身足够简单（一条主线 + 一个分叉 + 三个节点，
// 对应「任务线」与「灵感线」），用代码画比维护二进制素材更可控。
//
// 用法（在仓库根目录）：
//   dart run tool/make_launcher_icons.dart
//
// 抗锯齿用 4× 超采样后盒式降采样得到，不引入任何第三方包。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// 各密度目录对应的边长（与 Android 约定的 mipmap 尺寸一致）。
const Map<String, int> _densities = <String, int>{
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

/// 超采样倍数：4× 已经足够消除 48px 下的锯齿。
const int _supersample = 4;

/// 背景渐变：与 `ThemeData.colorSchemeSeed` 同色系。
const int _gradientTop = 0xFF5B93F8;
const int _gradientBottom = 0xFF2F6FEB;

const int _markColor = 0xFFFFFFFF;

void main() {
  final root = Directory.current.path;
  for (final entry in _densities.entries) {
    final path = '$root${Platform.pathSeparator}android${Platform.pathSeparator}app'
        '${Platform.pathSeparator}src${Platform.pathSeparator}main'
        '${Platform.pathSeparator}res${Platform.pathSeparator}${entry.key}'
        '${Platform.pathSeparator}ic_launcher.png';
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(_renderIcon(entry.value));
    stdout.writeln('已生成 $path（${entry.value}×${entry.value}）');
  }
}

/// 渲染一个尺寸为 [size] 的图标（PNG 字节）。
Uint8List _renderIcon(int size) {
  final work = size * _supersample;
  final high = _renderHighRes(work);
  return _encodePng(_downsample(high, work, size), size);
}

/// 高分辨率绘制（硬边），返回 RGBA 字节。
Uint8List _renderHighRes(int w) {
  final out = Uint8List(w * w * 4);
  final radius = w * 0.22;

  for (var y = 0; y < w; y += 1) {
    for (var x = 0; x < w; x += 1) {
      final px = x + 0.5;
      final py = y + 0.5;
      final offset = (y * w + x) * 4;

      if (!_insideRoundRect(px, py, 0, 0, w.toDouble(), w.toDouble(), radius)) {
        continue; // 圆角外保持透明
      }

      final t = (py / w).clamp(0.0, 1.0);
      var color = _lerpColor(_gradientTop, _gradientBottom, t);
      if (_onMark(px / w, py / w)) color = _markColor;

      out[offset] = (color >> 16) & 0xFF;
      out[offset + 1] = (color >> 8) & 0xFF;
      out[offset + 2] = color & 0xFF;
      out[offset + 3] = 0xFF;
    }
  }
  return out;
}

/// 图案：一条竖主线（三个节点）+ 从中间节点向右的分叉。
///
/// 坐标是 0..1 的归一化值，且全部落在中央约 44% 的区域里 ——
/// 安卓 8+ 的启动器会按自适应图标的安全区裁切，图案必须躲在安全区里。
bool _onMark(double x, double y) {
  const lineX = 0.38;
  const topY = 0.28;
  const bottomY = 0.72;
  const branchEndX = 0.63;
  const midY = 0.50;
  const stroke = 0.070;
  const nodeRadius = 0.086;

  // 竖主线 + 横分叉
  if (_distanceToSegment(x, y, lineX, topY, lineX, bottomY) <= stroke / 2) return true;
  if (_distanceToSegment(x, y, lineX, midY, branchEndX, midY) <= stroke / 2) return true;

  // 三个节点：起点、分叉点、终点
  for (final node in <List<double>>[
    <double>[lineX, topY],
    <double>[lineX, midY],
    <double>[lineX, bottomY],
    <double>[branchEndX, midY],
  ]) {
    final dx = x - node[0];
    final dy = y - node[1];
    if (dx * dx + dy * dy <= nodeRadius * nodeRadius) return true;
  }
  return false;
}

double _distanceToSegment(
  double px,
  double py,
  double x0,
  double y0,
  double x1,
  double y1,
) {
  final dx = x1 - x0;
  final dy = y1 - y0;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return math.sqrt((px - x0) * (px - x0) + (py - y0) * (py - y0));
  var t = ((px - x0) * dx + (py - y0) * dy) / lengthSquared;
  t = t.clamp(0.0, 1.0);
  final cx = px - (x0 + t * dx);
  final cy = py - (y0 + t * dy);
  return math.sqrt(cx * cx + cy * cy);
}

bool _insideRoundRect(
  double px,
  double py,
  double left,
  double top,
  double right,
  double bottom,
  double radius,
) {
  if (px < left || px > right || py < top || py > bottom) return false;
  final cx = px < left + radius
      ? left + radius
      : (px > right - radius ? right - radius : px);
  final cy = py < top + radius
      ? top + radius
      : (py > bottom - radius ? bottom - radius : py);
  final dx = px - cx;
  final dy = py - cy;
  return dx * dx + dy * dy <= radius * radius;
}

int _lerpColor(int from, int to, double t) {
  int channel(int shift) {
    final a = (from >> shift) & 0xFF;
    final b = (to >> shift) & 0xFF;
    return (a + (b - a) * t).round().clamp(0, 255);
  }

  return 0xFF000000 |
      (channel(16) << 16) |
      (channel(8) << 8) |
      channel(0);
}

/// 4×4 盒式降采样 —— 抗锯齿全靠这一步。
Uint8List _downsample(Uint8List high, int workSize, int size) {
  final out = Uint8List(size * size * 4);
  final samples = _supersample * _supersample;
  for (var y = 0; y < size; y += 1) {
    for (var x = 0; x < size; x += 1) {
      var r = 0;
      var g = 0;
      var b = 0;
      var a = 0;
      for (var sy = 0; sy < _supersample; sy += 1) {
        for (var sx = 0; sx < _supersample; sx += 1) {
          final hx = x * _supersample + sx;
          final hy = y * _supersample + sy;
          final offset = (hy * workSize + hx) * 4;
          final alpha = high[offset + 3];
          // 透明像素的颜色无意义，按 alpha 加权避免边缘发黑
          r += high[offset] * alpha;
          g += high[offset + 1] * alpha;
          b += high[offset + 2] * alpha;
          a += alpha;
        }
      }
      final offset = (y * size + x) * 4;
      final alphaSum = a == 0 ? 1 : a;
      out[offset] = (r ~/ alphaSum).clamp(0, 255);
      out[offset + 1] = (g ~/ alphaSum).clamp(0, 255);
      out[offset + 2] = (b ~/ alphaSum).clamp(0, 255);
      out[offset + 3] = a ~/ samples;
    }
  }
  return out;
}

// ---------------------------------------------------------------- PNG 编码

Uint8List _encodePng(Uint8List rgba, int size) {
  final builder = BytesBuilder();
  builder.add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder();
  ihdr.add(_uint32(size));
  ihdr.add(_uint32(size));
  ihdr.add(<int>[8, 6, 0, 0, 0]); // 8 位/通道，RGBA，无压缩预设，无滤波预设，非隔行
  builder.add(_chunk('IHDR', ihdr.toBytes()));

  // 每条扫描线前加一个 0（不使用滤波）
  final raw = BytesBuilder();
  for (var y = 0; y < size; y += 1) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * size * 4, (y + 1) * size * 4));
  }
  builder.add(_chunk('IDAT', ZLibCodec(level: 9).encode(raw.toBytes())));
  builder.add(_chunk('IEND', const <int>[]));

  return builder.toBytes();
}

List<int> _uint32(int value) => <int>[
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final builder = BytesBuilder();
  builder.add(_uint32(data.length));
  builder.add(typeBytes);
  builder.add(data);
  builder.add(_uint32(_crc32(<int>[...typeBytes, ...data])));
  return builder.toBytes();
}

final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i += 1) {
    var c = i;
    for (var k = 0; k < 8; k += 1) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
