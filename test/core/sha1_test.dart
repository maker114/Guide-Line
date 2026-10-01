import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/sha1.dart';

/// 补位边界的期望值，由 **.NET `System.Security.Cryptography.SHA1`** 独立算出：
///
/// ```powershell
/// $h = [System.Security.Cryptography.SHA1]::Create()
/// $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('a' * 55))
/// ```
///
/// 为什么必须独立算：自实现哈希最容易出的错是**"看起来对"** —— 长度对、
/// 字符集对、每次还稳定，但位运算错一步值就是另一个。拿自己的输出回填期望值
/// 等于没测。这一组同时和 RFC 3174 的官方向量交叉验证过。
const _a55 = 'c1c8bbdc22796e28c0e15163d20899b65621d65a';
const _a56 = 'c2db330f6083854c99d4b5bfb6e8f29f201be699';
const _a57 = 'f08f24908d682555111be7ff6f004e78283d989a';
const _a63 = '03f09f5b158a7a8cdad920bddc29b81c18a551f5';
const _a64 = '0098ba824b5c16427bd7a1122a5a442a25ec644d';
const _a65 = '11655326c708d70319be2610e8a57d9a5b959d3b';

void main() {
  /// RFC 3174 §7.3 的官方测试向量，加上 FIPS 180-1 里那几条常用的。
  ///
  /// 为什么逐条钉死而不用"算出来看着像 40 位十六进制"当验收：
  /// 自己实现的哈希**最容易出的错是"看起来对"** —— 摘要长度对、字符集对、
  /// 每次调用还稳定，但位运算某一步错了，值就是另一个。这种错不会自己暴露，
  /// 只会让"本地指纹"从此永远对不上任何外部值。所以拿官方向量当尺子。
  group('SHA-1 官方测试向量', () {
    void check(String message, String expectedHex) {
      expect(
        Sha1.hex(utf8.encode(message)),
        expectedHex,
        reason: '输入：${jsonEncode(message)}',
      );
    }

    test('空串', () {
      check('', 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
    });

    test('abc', () {
      check('abc', 'a9993e364706816aba3e25717850c26c9cd0d89d');
    });

    test('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq', () {
      check(
        'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
        '84983e441c3bd26ebaae4aa1f95129e5e54670f1',
      );
    });

    test('a 重复 100 万次（跨多个 64 字节块）', () {
      final million = 'a' * 1000000;
      expect(
        Sha1.hex(utf8.encode(million)),
        '34aa973cd4c4daa4f61eeb2bdbad27316534016f',
      );
    });

    test('长消息：abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn'
        'hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu', () {
      check(
        'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn'
        'hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu',
        'a49b2446a02c645bf419f995b67091253a04a259',
      );
    });

    test('补位边界：55 / 56 / 57 / 63 / 64 / 65 字节', () {
      // 这一组是自实现最容易翻车的地方：补位后长度落在"56 的余数"上时，
      // 要多补**一整块**。只测短串（一个块内）和长串（多块）照不到这里。
      check('a' * 55, _a55);
      check('a' * 56, _a56);
      check('a' * 57, _a57);
      check('a' * 63, _a63);
      check('a' * 64, _a64);
      check('a' * 65, _a65);
    });
  });

  test('摘要长度与字符集：20 字节 / 40 位小写十六进制', () {
    final bytes = Sha1.digest(utf8.encode('guideline'));
    expect(bytes.length, 20);
    final hex = Sha1.hex(utf8.encode('guideline'));
    expect(hex.length, 40);
    expect(RegExp(r'^[0-9a-f]{40}$').hasMatch(hex), isTrue);
  });

  test('同样的输入给同样的结果（确定性）', () {
    final a = Sha1.hex(utf8.encode('同一份数据'));
    final b = Sha1.hex(utf8.encode('同一份数据'));
    expect(a, b);
  });

  test('差一个字节就完全不同（雪崩）', () {
    final a = Sha1.hex(utf8.encode('清单 2/6'));
    final b = Sha1.hex(utf8.encode('清单 3/6'));
    expect(a, 'f15547bf01d5821751fffc2697db1db7da48100d');
    expect(b, '5723b86b583cf91941c2cc9a4a17a4a3a7d2e68e');
    expect(a, isNot(b));
  });

  test('非 ASCII 按 UTF-8 字节算，不是按 UTF-16 code unit', () {
    // 中文字符 UTF-8 是 3 字节。若实现按 `codeUnits` 喂进去，值就会不同 ——
    // 这条把"吃的是哪种字节"钉死，防止以后有人顺手改成 codeUnits。
    const text = '数据契约';
    expect(
      Sha1.hex(utf8.encode(text)),
      'ef7991dfacf3bd945b83ee00fe7f223f12735b09',
    );
    final byCodeUnits = Sha1.hex(
      text.codeUnits.map((unit) => unit & 0xFF).toList(),
    );
    expect(byCodeUnits, isNot('ef7991dfacf3bd945b83ee00fe7f223f12735b09'));
  });
}
