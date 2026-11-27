import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/sha256.dart';

/// SHA-256 的正確性用 FIPS 180-4 的官方测试向量钉住。
///
/// 服务端与客户端必须算出同一个证书指纹，算法一旦写错，TLS 固定就永远对不上；
/// 这种错在真实网络里只会表现为"握手失败"，很难反推到哈希实现，所以在这里先钉死。
void main() {
  test('空串、abc、官方两段样例', () {
    expect(
      sha256Hex(const <int>[]),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256Hex(
        utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      ),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
  });

  test('一百万个 a', () {
    expect(
      sha256Hex(List<int>.filled(1000000, 0x61)),
      'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
    );
  });

  test('摘要长度为 32 字节、十六进制小写', () {
    final bytes = sha256Bytes(const <int>[1, 2, 3]);
    expect(bytes.length, 32);
    expect(sha256Hex(const <int>[1, 2, 3]), matches(RegExp(r'^[0-9a-f]{64}$')));
  });
}
