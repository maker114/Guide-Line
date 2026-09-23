import 'dart:math';

/// ID 与时间。
///
/// ID 一律**由客户端生成**（ADR-002），因此离线也能创建记录；
/// 不引入第三方 uuid 包，避免无谓依赖。
class Ids {
  static final Random _random = Random.secure();

  /// UUID v4（小写、带连字符，符合《数据契约》§1）。
  static String uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256), growable: false);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
        '-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// 记录级时间戳：**客户端生成**（ADR-067），毫秒整数。
  static int nowMillis() => DateTime.now().millisecondsSinceEpoch;

  /// 今天的 `"YYYY-MM-DD"`（本地日历，不涉时区换算）。
  static String todayDate([DateTime? now]) {
    final d = now ?? DateTime.now();
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }
}

/// 同一父节点下兄弟排序的间隔（《数据契约》§1 / 设计文档 4.11）。
const int orderStep = 1000;

/// 排序键：`order` 升序，`order` 相同则按 `id` 保证确定性。
int compareByOrder(int orderA, String idA, int orderB, String idB) {
  final byOrder = orderA.compareTo(orderB);
  if (byOrder != 0) return byOrder;
  return idA.compareTo(idB);
}
