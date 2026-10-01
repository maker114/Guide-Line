// 一次性校验脚本（**已入库**：`tool/` 是仓库路径，被 gitignore 的是 `.tools/`）：把生成的 PNG 解回来，用字符画确认图案。
import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) {
  final path = args.isEmpty
      ? 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png'
      : args.first;
  final bytes = File(path).readAsBytesSync();
  stdout.writeln('file=$path bytes=${bytes.length}');

  var offset = 8;
  var width = 0;
  var height = 0;
  final idat = BytesBuilder();
  while (offset < bytes.length) {
    final length = _readUint32(bytes, offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    final data = bytes.sublist(offset + 8, offset + 8 + length);
    if (type == 'IHDR') {
      width = _readUint32(data, 0);
      height = _readUint32(data, 4);
      stdout.writeln(
        'IHDR ${width}x$height depth=${data[8]} colorType=${data[9]} '
        'compression=${data[10]} filter=${data[11]} interlace=${data[12]}',
      );
    } else if (type == 'IDAT') {
      idat.add(data);
    } else if (type == 'IEND') {
      break;
    }
    offset += 12 + length;
  }

  final raw = Uint8List.fromList(ZLibCodec().decode(idat.toBytes()));
  const columns = 32;
  final rows = (columns * height / width).round();
  final buffer = StringBuffer();
  for (var row = 0; row < rows; row += 1) {
    for (var col = 0; col < columns; col += 1) {
      final x = (col * width / columns).floor().clamp(0, width - 1);
      final y = (row * height / rows).floor().clamp(0, height - 1);
      final p = y * (width * 4 + 1) + 1 + x * 4;
      final r = raw[p];
      final g = raw[p + 1];
      final b = raw[p + 2];
      final a = raw[p + 3];
      if (a < 40) {
        buffer.write('.');
      } else if (r > 200 && g > 200 && b > 200) {
        buffer.write('#'); // 白色图案
      } else {
        buffer.write('+'); // 渐变背景
      }
    }
    buffer.writeln();
  }
  stdout.write(buffer.toString());
}

int _readUint32(List<int> data, int at) =>
    (data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3];
