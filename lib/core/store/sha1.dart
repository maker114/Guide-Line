import 'dart:typed_data';

/// SHA-1（RFC 3174）的**最小实现**。
///
/// 为什么自己写而不引 `package:crypto`：
///   · 这里只用它算"本地数据指纹"，一个算法、一种用法，不构成依赖理由；
///   · `lib/core` 的既有风格是**能不引第三方就不引**（现在 core 里一个
///     第三方包都没有），加一个包只为 60 行代码不划算；
///   · 自己写就能被[单测]按 RFC 的官方测试向量逐条钉住 —— 引包反而只能信它。
///
/// 为什么是 SHA-1 而不是"随便一个短哈希"：
///   · 界面要显示 7 位十六进制（[shortSha] 的惯例）。**7 位只有 28 bit**，
///     用 CRC / FNV 这类 32 位哈希取前 7 位，碰撞概率在几万条记录上就不可忽略；
///     SHA-1 取前 7 位至少是密码学散列的前缀，分布均匀得多。
///   · 名字里带"1"也提醒读的人：**这不是安全用途**，只是内容指纹。
///
/// ⚠️ 口径：**本地指纹与 GitHub 的内容码不是一回事**。GitHub 的内容码是
/// 对**上传的 gzip 字节**算的 blob sha，而上传字节里带 `exportedAt` 时间戳，
/// 本地复现不出来。所以两者**不能直接判等**，界面上也不该把它们并排比较。
abstract final class Sha1 {
  /// 算 [bytes] 的 SHA-1，返回 20 字节摘要。
  static Uint8List digest(List<int> bytes) {
    final h = <int>[
      0x67452301,
      0xEFCDAB89,
      0x98BADCFE,
      0x10325476,
      0xC3D2E1F0,
    ];

    // 补位：0x80 + 若干 0 + 64 位大端长度。
    final messageLengthBits = bytes.length * 8;
    final withPadding = <int>[...bytes, 0x80];
    while (withPadding.length % 64 != 56) {
      withPadding.add(0);
    }
    // 长度用 64 位大端；Dart 的 int 是 64 位，高位部分用除法拆出来。
    final highBits = messageLengthBits ~/ 0x100000000;
    final lowBits = messageLengthBits & 0xFFFFFFFF;
    for (var shift = 24; shift >= 0; shift -= 8) {
      withPadding.add((highBits >> shift) & 0xFF);
    }
    for (var shift = 24; shift >= 0; shift -= 8) {
      withPadding.add((lowBits >> shift) & 0xFF);
    }

    final w = Uint32List(80);
    for (var chunk = 0; chunk < withPadding.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        final base = chunk + i * 4;
        w[i] = (withPadding[base] << 24) |
            (withPadding[base + 1] << 16) |
            (withPadding[base + 2] << 8) |
            withPadding[base + 3];
      }
      for (var i = 16; i < 80; i++) {
        w[i] = _rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }

      var a = h[0];
      var b = h[1];
      var c = h[2];
      var d = h[3];
      var e = h[4];

      for (var i = 0; i < 80; i++) {
        final (f, k) = switch (i) {
          < 20 => ((b & c) | ((~b) & d), 0x5A827999),
          < 40 => (b ^ c ^ d, 0x6ED9EBA1),
          < 60 => ((b & c) | (b & d) | (c & d), 0x8F1BBCDC),
          _ => (b ^ c ^ d, 0xCA62C1D6),
        };
        final temp = (_rotateLeft(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
        e = d;
        d = c;
        c = _rotateLeft(b, 30);
        b = a;
        a = temp;
      }

      h[0] = (h[0] + a) & 0xFFFFFFFF;
      h[1] = (h[1] + b) & 0xFFFFFFFF;
      h[2] = (h[2] + c) & 0xFFFFFFFF;
      h[3] = (h[3] + d) & 0xFFFFFFFF;
      h[4] = (h[4] + e) & 0xFFFFFFFF;
    }

    final out = Uint8List(20);
    for (var i = 0; i < 5; i++) {
      out[i * 4] = (h[i] >> 24) & 0xFF;
      out[i * 4 + 1] = (h[i] >> 16) & 0xFF;
      out[i * 4 + 2] = (h[i] >> 8) & 0xFF;
      out[i * 4 + 3] = h[i] & 0xFF;
    }
    return out;
  }

  /// 摘要的小写十六进制（40 位）。
  static String hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in digest(bytes)) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static int _rotateLeft(int value, int bits) =>
      ((value << bits) | (value >> (32 - bits))) & 0xFFFFFFFF;
}
