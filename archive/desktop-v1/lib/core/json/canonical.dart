import 'dart:convert';

import '../models/entity.dart';

/// 规范化 JSON（《数据契约》§2 / §8）。
///
/// 这是全项目**唯一**的序列化出口：任何绕过它去 `jsonEncode` 的写法都会破坏
/// 「逐字节可比」的契约，进而造成两端静默分叉。
class Canonical {
  static const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

  static final RegExp _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// 文档落盘文本：2 空格缩进 + 末尾**恰好一个** LF。
  static String documentText(Object? value) => '${_pretty.convert(value)}\n';

  /// 紧凑形式（仅用于摘要/哈希，不用于落盘）。
  static String compact(Object? value) => jsonEncode(value);

  static Object? decode(String text) => jsonDecode(text);

  // ---------- 容错读取（《数据契约》§8） ----------

  static String? readString(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is String) return value;
    issues.error('$field 期望 string，实际 ${value.runtimeType} —— 按 null 处理');
    return null;
  }

  static int? readInt(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is double) {
      if (value == value.roundToDouble()) {
        issues.warn('$field 是浮点整数值 —— 已转为 int');
        return value.toInt();
      }
      issues.error('$field 是小数，契约要求 int64 毫秒 —— 丢弃');
      return null;
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) {
        issues.warn('$field 是字符串数字 —— 已转为 int');
        return parsed;
      }
    }
    issues.error('$field 期望 int64，实际 ${value.runtimeType} —— 按 null 处理');
    return null;
  }

  static bool? readBool(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is String) {
      if (value == 'true') {
        issues.warn('$field 是字符串布尔 —— 已转为 bool');
        return true;
      }
      if (value == 'false') {
        issues.warn('$field 是字符串布尔 —— 已转为 bool');
        return false;
      }
    }
    issues.error('$field 期望 bool，实际 ${value.runtimeType} —— 按默认值处理');
    return null;
  }

  /// 日期字段：必须是 `"YYYY-MM-DD"`，否则置空并记录。
  static String? readDate(Object? value, String field, DecodeIssues issues) {
    if (value == null) return null;
    if (value is String && _datePattern.hasMatch(value)) return value;
    issues.error('$field 不是 "YYYY-MM-DD" 形态：$value —— 置为 null');
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
}
