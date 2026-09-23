import 'dart:math';

/// 恢复码（《同步与云函数契约》§4.4）。
///
/// **客户端生成、服务端只存哈希**；这是换机 / 重装后取回数据的唯一凭证，
/// 因此 UI 必须强制用户抄写或离线保存，且绝不写入日志。
class RecoveryCode {
  /// 字母表：剔除易混字符 0 / O / 1 / I（与云函数 `RECOVERY_ALPHABET` 一致）。
  static const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static const int length = 24;

  static final Random _random = Random.secure();

  static String generate() {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i += 1) {
      buffer.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  /// 归一化：大写 + 去掉分隔符（服务端同样处理）。
  static String normalize(String input) =>
      input.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  static bool isValid(String input) => normalize(input).length == length;

  /// 展示用分组（每 4 位一组），便于用户抄写核对。
  static String formatForDisplay(String code) {
    final normalized = normalize(code);
    final parts = <String>[];
    for (var i = 0; i < normalized.length; i += 4) {
      parts.add(normalized.substring(i, i + 4 > normalized.length ? normalized.length : i + 4));
    }
    return parts.join('-');
  }
}
