import '../models/entity.dart';
import '../models/enums.dart';
import '../models/event.dart';
import '../models/inspiration.dart';
import '../models/project.dart';
import '../models/task.dart';
import 'canonical.dart';

/// 一份文档（《数据契约》§2）：本地文件与云端记录**逐字节同构**。
///
/// `version` / `updatedAt` / `lastTxId` 由服务端生成，客户端只读；
/// 本地文件的 `version` 是**唯一**的版本存放处（`sync_state.json` 不重复存）。
class Document {
  const Document({
    required this.name,
    required this.version,
    required this.updatedAt,
    required this.lastTxId,
    required this.items,
  });

  factory Document.empty(DocName name) => Document(
        name: name,
        version: 0,
        updatedAt: null,
        lastTxId: null,
        items: const <Entity>[],
      );

  final DocName name;
  final int version;
  final int? updatedAt;
  final String? lastTxId;
  final List<Entity> items;

  Iterable<Project> get projectItems => items.whereType<Project>();

  Iterable<Inspiration> get inspirationItems => items.whereType<Inspiration>();

  Iterable<Event> get eventItems => items.whereType<Event>();

  Iterable<Task> get taskItems => items.whereType<Task>();

  int get liveCount => items.where((e) => !e.deleted).length;

  int get tombstoneCount => items.where((e) => e.deleted).length;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': version,
      'updated_at': updatedAt,
      'last_tx_id': lastTxId,
      'payload': <String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(growable: false),
      },
    };
  }

  /// 落盘文本：与 `test/contract/sample/*.json` 逐字节一致。
  String toCanonicalText() => Canonical.documentText(toJson());

  /// 仅 `payload` 的 JSON 字符串（供同步接口传递；接口层只认字符串）。
  String payloadJson() => Canonical.compact(<String, dynamic>{
        'items': items.map((e) => e.toJson()).toList(growable: false),
      });

  Document copyWith({
    int? version,
    Object? updatedAt = _unset,
    Object? lastTxId = _unset,
    List<Entity>? items,
  }) {
    return Document(
      name: name,
      version: version ?? this.version,
      updatedAt: updatedAt == _unset ? this.updatedAt : updatedAt as int?,
      lastTxId: lastTxId == _unset ? this.lastTxId : lastTxId as String?,
      items: items ?? this.items,
    );
  }

  /// 解析文档文本。**任何单条记录的损坏都不应导致整包失败**（《数据契约》§8）。
  static Document parse(DocName name, String text, DecodeIssues issues) {
    Object? root;
    try {
      root = Canonical.decode(text);
    } catch (error) {
      issues.error('${name.fileName} 不是合法 JSON：$error');
      return Document.empty(name);
    }

    final map = Canonical.readObject(root, '${name.fileName}.root', issues);
    if (map == null) return Document.empty(name);

    final version = Canonical.readInt(map['version'], '${name.fileName}.version', issues) ?? 0;
    final updatedAt = Canonical.readInt(map['updated_at'], '${name.fileName}.updated_at', issues);
    final lastTxId = Canonical.readString(map['last_tx_id'], '${name.fileName}.last_tx_id', issues);

    final payload = Canonical.readObject(map['payload'], '${name.fileName}.payload', issues);
    final rawItems = payload == null
        ? null
        : Canonical.readArray(payload['items'], '${name.fileName}.payload.items', issues);

    final items = <Entity>[];
    if (rawItems != null) {
      for (var i = 0; i < rawItems.length; i += 1) {
        final raw = Canonical.readObject(rawItems[i], '${name.fileName}.items[$i]', issues);
        if (raw == null) continue;
        final parsed = parseItem(name, raw, i, issues);
        if (parsed != null) items.add(parsed);
      }
    }

    return Document(
      name: name,
      version: version,
      updatedAt: updatedAt,
      lastTxId: lastTxId,
      items: items,
    );
  }

  /// 从「云端返回的 payload JSON」构造文档（Pull 用）。
  ///
  /// 接口层只传 `payload` 字符串（形如 `{"items":[...]}`），这里负责把它变成实体列表，
  /// 并带上服务端给的 `version` / `updatedAt` / `lastTxId`。
  static Document fromPayloadJson({
    required DocName name,
    required int version,
    required String payloadJson,
    required DecodeIssues issues,
    int? updatedAt,
    String? lastTxId,
  }) {
    Object? payload;
    try {
      payload = Canonical.decode(payloadJson);
    } catch (error) {
      issues.error('${name.fileName} 的 payload 不是合法 JSON：$error');
      return Document.empty(name)
          .copyWith(version: version, updatedAt: updatedAt, lastTxId: lastTxId);
    }

    final map = Canonical.readObject(payload, '${name.fileName}.payload', issues);
    final rawItems = map == null
        ? null
        : Canonical.readArray(map['items'], '${name.fileName}.payload.items', issues);

    final items = <Entity>[];
    if (rawItems != null) {
      for (var i = 0; i < rawItems.length; i += 1) {
        final raw = Canonical.readObject(rawItems[i], '${name.fileName}.items[$i]', issues);
        if (raw == null) continue;
        final parsed = parseItem(name, raw, i, issues);
        if (parsed != null) items.add(parsed);
      }
    }

    return Document(
      name: name,
      version: version,
      updatedAt: updatedAt,
      lastTxId: lastTxId,
      items: items,
    );
  }

  /// 按文档类型分发到对应实体；墓碑骨架优先识别（《数据契约》§3.5）。
  static Entity? parseItem(
    DocName name,
    Map<String, dynamic> raw,
    int index,
    DecodeIssues issues,
  ) {
    if (Tombstone.matches(raw)) {
      final id = Canonical.readString(raw['id'], '${name.fileName}.items[$index].id', issues);
      final purgedAt =
          Canonical.readInt(raw['purged_at'], '${name.fileName}.items[$index].purged_at', issues);
      if (id == null || purgedAt == null) {
        issues.error('${name.fileName}.items[$index]：墓碑骨架缺少 id / purged_at —— 丢弃');
        return null;
      }
      return Tombstone(id: id, purgedAt: purgedAt);
    }

    switch (name) {
      case DocName.projects:
        return Project.fromJson(raw, issues);
      case DocName.inspirations:
        return Inspiration.fromJson(raw, issues);
      case DocName.events:
        return Event.fromJson(raw, issues);
      case DocName.tasks:
        return Task.fromJson(raw, issues);
    }
  }
}

const Object _unset = Object();
