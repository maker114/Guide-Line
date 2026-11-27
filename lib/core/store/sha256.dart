import 'dart:typed_data';

/// 纯 Dart 的 SHA-256（FIPS 180-4）。
///
/// 为什么自己写一份：服务端同步要用它算**证书指纹**与**备份内容指纹**，而
/// `lib/core` 不许依赖 Flutter、仓库里也已经有一份手写的 `sha1.dart`
/// （同一个理由：不为一个哈希函数去动整条依赖链，`pubspec.lock` 会跟着漂）。
///
/// 正确性由 `test/core/sha256_test.dart` 用官方测试向量钉住，**不要**在别处
/// 再写第二份 —— 运维脚本与客户端必须算出同一个指纹，否则自签证书永远对不上。

/// 初始哈希值（前 8 个质数平方根的小数部分）。
const List<int> _initial = <int>[
  0x6a09e667,
  0xbb67ae85,
  0x3c6ef372,
  0xa54ff53a,
  0x510e527f,
  0x9b05688c,
  0x1f83d9ab,
  0x5be0cd19,
];

/// 64 轮的轮常量（前 64 个质数立方根的小数部分）。
const List<int> _round = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _mask(int value) => value & 0xFFFFFFFF;

int _rotateRight(int value, int bits) =>
    _mask((value >> bits) | (value << (32 - bits)));

int _choose(int x, int y, int z) => _mask((x & y) ^ ((~x) & z));

int _majority(int x, int y, int z) => _mask((x & y) ^ (x & z) ^ (y & z));

int _bigSigma0(int x) =>
    _rotateRight(x, 2) ^ _rotateRight(x, 13) ^ _rotateRight(x, 22);

int _bigSigma1(int x) =>
    _rotateRight(x, 6) ^ _rotateRight(x, 11) ^ _rotateRight(x, 25);

int _smallSigma0(int x) =>
    _rotateRight(x, 7) ^ _rotateRight(x, 18) ^ (x >> 3);

int _smallSigma1(int x) =>
    _rotateRight(x, 17) ^ _rotateRight(x, 19) ^ (x >> 10);

/// 算 SHA-256，返回 32 字节的原始摘要。
List<int> sha256Bytes(List<int> input) {
  final h = List<int>.of(_initial);
  final length = input.length;
  final paddedLength = ((length + 9 + 63) ~/ 64) * 64;
  final message = Uint8List(paddedLength)..setRange(0, length, input);
  message[length] = 0x80;

  // 末尾 8 字节写**比特长度**（大端）。`length * 8` 在 2^53 位以内不会溢出。
  final bitLength = length * 8;
  for (var i = 0; i < 8; i++) {
    message[paddedLength - 1 - i] = (bitLength >> (8 * i)) & 0xFF;
  }

  final w = List<int>.filled(64, 0);
  for (var offset = 0; offset < paddedLength; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final at = offset + i * 4;
      w[i] = _mask(
        (message[at] << 24) |
            (message[at + 1] << 16) |
            (message[at + 2] << 8) |
            message[at + 3],
      );
    }
    for (var i = 16; i < 64; i++) {
      w[i] = _mask(
        _smallSigma1(w[i - 2]) + w[i - 7] + _smallSigma0(w[i - 15]) + w[i - 16],
      );
    }

    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    var f = h[5];
    var g = h[6];
    var hh = h[7];

    for (var i = 0; i < 64; i++) {
      final t1 = _mask(hh + _bigSigma1(e) + _choose(e, f, g) + _round[i] + w[i]);
      final t2 = _mask(_bigSigma0(a) + _majority(a, b, c));
      hh = g;
      g = f;
      f = e;
      e = _mask(d + t1);
      d = c;
      c = b;
      b = a;
      a = _mask(t1 + t2);
    }

    h[0] = _mask(h[0] + a);
    h[1] = _mask(h[1] + b);
    h[2] = _mask(h[2] + c);
    h[3] = _mask(h[3] + d);
    h[4] = _mask(h[4] + e);
    h[5] = _mask(h[5] + f);
    h[6] = _mask(h[6] + g);
    h[7] = _mask(h[7] + hh);
  }

  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (h[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (h[i] >> 8) & 0xFF;
    out[i * 4 + 3] = h[i] & 0xFF;
  }
  return out;
}

/// 小写十六进制（证书指纹、内容指纹都用这一种写法）。
String sha256Hex(List<int> input) {
  final bytes = sha256Bytes(input);
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
