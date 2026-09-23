import 'dart:convert';
import 'dart:io';

import '../json/canonical.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import '../models/enums.dart';

/// 导出文件的编解码（**纯 Dart，可单测**）。
///
/// 导出载荷就是**整份数据文件**再加三个自描述字段，然后用 gzip 压缩：
///
/// ```json
/// { "app": "GuideLine", "kind": "full-export", "exportedAt": 1788652800000,
///   "schemaVersion": 2, "savedAt": 1788652800000, "collections": { ... } }
/// ```
///
/// 为什么不另立一套格式：
///   · 导入时可以直接复用 [StoreFile.parse]，连 **v1 四文档信封**也一并读得进来；
///   · 万一 gzip 坏了，去掉压缩仍是人可读、可手工抢救的 JSON。
class ExportCodec {
  const ExportCodec._();

  static const String appName = 'GuideLine';

  /// `kind` 用于将来区分「全量导出 / 单集合导出」。
  static const String fullExportKind = 'full-export';

  /// 编码：整份数据 → gzip 字节。
  static List<int> encode(StoreFile store, {required int exportedAt}) {
    final map = <String, dynamic>{
      'app': appName,
      'kind': fullExportKind,
      'exportedAt': exportedAt,
      ...store.copyWith(savedAt: exportedAt).toJson(),
    };
    return gzip.encode(utf8.encode(Canonical.documentText(map)));
  }

  /// 解码：gzip 或纯文本 JSON 都能读；结构问题按契约降级并记入 [issues]。
  static ExportPayload decode(List<int> bytes, DecodeIssues issues) {
    final text = _toText(bytes, issues);
    if (text == null) {
      return _rejected();
    }

    final Object? root;
    try {
      root = Canonical.decode(text);
    } catch (error) {
      issues.error('导出文件不是合法 JSON：$error');
      return _rejected();
    }

    if (root is! Map) {
      issues.error('导出文件的根不是对象，无法当作数据文件');
      return _rejected();
    }

    // 「像不像我们的数据文件」必须显式判断：`StoreFile.parse` 对任何输入都会返回
    // 一份四集合齐全（但全空）的结构，光看「解析有没有抛异常」会把垃圾文件当好数据。
    final hasCollections = root.containsKey('collections');
    final hasLegacyEnvelope = root.containsKey('projects.json');
    if (!hasCollections && !hasLegacyEnvelope) {
      issues.error('导出文件里既没有 collections，也没有 v1 四文档信封');
      return _rejected();
    }

    final rawVersion = root['schemaVersion'];
    if (rawVersion is int && rawVersion > StoreFile.currentSchemaVersion) {
      issues.error('数据文件版本 $rawVersion 高于本应用支持的 ${StoreFile.currentSchemaVersion}');
      return _rejected();
    }

    final store = StoreFile.parse(text, issues);
    final exportedAt = root['exportedAt'];

    return ExportPayload(
      store: store,
      exportedAt: exportedAt is int ? exportedAt : null,
      counts: _countsOf(store),
      readable: true,
    );
  }

  static ExportPayload _rejected() => ExportPayload(
        store: StoreFile.empty(),
        exportedAt: null,
        counts: _countsOf(StoreFile.empty()),
        readable: false,
      );

  /// 先按 gzip 解，失败再按明文解 —— 两种都失败才算读不了。
  static String? _toText(List<int> bytes, DecodeIssues issues) {
    try {
      return utf8.decode(gzip.decode(bytes));
    } catch (_) {
      // 不是 gzip，继续尝试明文
    }
    try {
      return utf8.decode(bytes);
    } catch (error) {
      issues.error('导出文件既不是 gzip 也不是文本：$error');
      return null;
    }
  }

  static Map<DocName, int> _countsOf(StoreFile store) => <DocName, int>{
        for (final name in DocName.values) name: store.documentOf(name).items.length,
      };
}

/// 解码结果 + 给「导入前确认」用的摘要。
class ExportPayload {
  const ExportPayload({
    required this.store,
    required this.exportedAt,
    required this.counts,
    required this.readable,
  });

  final StoreFile store;

  /// 导出时间（旧格式或明文文件可能没有）
  final int? exportedAt;

  /// 各集合的记录条数（**含墓碑**，因为导入就是整体替换）
  final Map<DocName, int> counts;

  /// 是否解析出了可用结构
  final bool readable;

  int get total => counts.values.fold(0, (sum, value) => sum + value);

  String get countSummary => DocName.values
      .map((name) => '${_collectionLabel(name)} ${counts[name] ?? 0}')
      .join(' · ');

  static String _collectionLabel(DocName name) {
    switch (name) {
      case DocName.projects:
        return '项目';
      case DocName.inspirations:
        return '灵感';
      case DocName.events:
        return '事件';
      case DocName.tasks:
        return '任务';
    }
  }
}
