import 'dart:convert';

import '../models/entity.dart';

/// 规范化 JSON（《数据契约》§2 / §8）。
///
/// 这是全项目**唯一**的序列化出口：任何绕过它去 `jsonEncode` 的写法都会破坏
/// 「逐字节可比」的契约，进而造成两端静默走偏。
class Canonical {
  static const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

  static final RegExp _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// 文档落盘文本：2 空格缩进 + 末尾**恰好一个** LF。
  static String documentText(Object? value) => '${_pretty.convert(value)}\n';

  static Object? decode(String text) => jsonDecode(text);

  // ---------- 容错读取（《数据契约》§8） ----------

  static String? readString(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is String) return value;
    issues.error('$field 期望 string，实际 ${value.runtimeType}，已按 null 处理');
    return null;
  }

  static int? readInt(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) {
      if (value == value.roundToDouble()) {
        issues.warn('$field 是浮点整数值，已转为 int');
        return value.toInt();
      }
      issues.error('$field 是小数，契约要求 int64 毫秒，已丢弃');
      return null;
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) {
        issues.warn('$field 是字符串数字，已转为 int');
        return parsed;
      }
    }
    issues.error('$field 期望 int64，实际 ${value.runtimeType}，已按 null 处理');
    return null;
  }

  static bool? readBool(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is String) {
      if (value == 'true') {
        issues.warn('$field 是字符串布尔，已转为 bool');
        return true;
      }
      if (value == 'false') {
        issues.warn('$field 是字符串布尔，已转为 bool');
        return false;
      }
    }
    issues.error('$field 期望 bool，实际 ${value.runtimeType}，已按默认值处理');
    return null;
  }

  /// 日期字段：必须是 `"YYYY-MM-DD"`，否则置空并记录。
  static String? readDate(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is String && _datePattern.hasMatch(value)) return value;
    issues.error('$field 不是 "YYYY-MM-DD" 形态：$value，已置为 null');
    return null;
  }

  static Map<String, dynamic>? readObject(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    issues.error('$field 期望 object，实际 ${value.runtimeType}');
    return null;
  }

  static List<dynamic>? readArray(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is List) return value;
    issues.error('$field 期望 array，实际 ${value.runtimeType}');
    return null;
  }

  /// 未知字段透传：**保持原有顺序**，追加在已知字段之后。
  static Map<String, dynamic> readExtra(Map<String, dynamic> json, Set<String> knownKeys) {
    final out = <String, dynamic>{};
    for (final entry in json.entries) {
      if (!knownKeys.contains(entry.key)) out[entry.key] = entry.value;
    }
    return out;
  }

  /// 字符串数组（灵感的 `tags`）：逐项 `trim()`、丢掉空串、**按出现顺序去重**。
  ///
  /// 容错口径与其它字段一致 —— 坏值不抛异常、记一条 error 后按能用的部分处理：
  ///   · 不是数组 → 记错并当作空；
  ///   · 数组里有非字符串项 → 跳过那一项并记错，不让整条记录废掉。
  ///
  /// 去重是有意的：标签是"集合"语义，存了 `["a","a"]` 没有任何好处，
  /// 而保留首次出现的顺序能让样本与界面稳定，不随 Map 的遍历顺序飘。
  static List<String> readStringList(Object? value, String field, DecodeIssues issues) {
    if (value == null) return const <String>[];
    if (value is! List) {
      issues.error('$field 期望 array，实际 ${value.runtimeType}，已按空处理');
      return const <String>[];
    }
    final out = <String>[];
    for (final item in value) {
      if (item is! String) {
        issues.error('$field 里有非字符串项：${item.runtimeType}，已跳过该项');
        continue;
      }
      final trimmed = item.trim();
      if (trimmed.isEmpty) continue;
      if (!out.contains(trimmed)) out.add(trimmed);
    }
    return out;
  }

  /// 色值形态：`#rrggbb`（小写，六位十六进制）。
  ///
  /// 放在 core 而不是界面层，是因为**模型校验与界面取色必须用同一套口径** ——
  /// 各写一份迟早会出现"界面收下了、模型读不出来"的分歧。
  static final RegExp hexColorPattern = RegExp(r'^#[0-9a-f]{6}$');

  /// `#RRGGBB`（大小写均可、允许前后空格）→ 规范化的小写 `#rrggbb`；不认识就返回 `null`。
  static String? normalizeHexColor(String? value) {
    if (value == null) return null;
    final normalized = value.trim().toLowerCase();
    return hexColorPattern.hasMatch(normalized) ? normalized : null;
  }

  /// 标识色字段（项目 / 事件共用）：不是 `#rrggbb` 就置空并记一条 error。
  ///
  /// 与 [normalizeHexColor] 是同一套口径 —— 界面取色、模型校验、写入侧校验
  /// 共用一份，免得出现"界面收下了、模型读不出来"的分歧。
  static String? readHexColor(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is String) {
      final normalized = normalizeHexColor(value);
      if (normalized != null) return normalized;
    }
    issues.error('$field 不是 "#rrggbb" 形态：$value，已置为 null');
    return null;
  }
}
