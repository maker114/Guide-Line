import '../json/canonical.dart';
import '../models/enums.dart';

/// 同步元数据（《同步与云函数契约》§1）。
///
/// **不存版本号** —— 版本号只存在 4 份本地文档的外层（避免两处存放不一致）。
class SyncState {
  const SyncState({
    required this.schemaVersion,
    required this.accountId,
    required this.firstSyncDone,
    required this.lastSyncAt,
    this.deviceId,
  });

  static const int currentSchemaVersion = 1;

  static const SyncState initial = SyncState(
    schemaVersion: currentSchemaVersion,
    accountId: null,
    firstSyncDone: false,
    lastSyncAt: null,
    deviceId: null,
  );

  final int schemaVersion;
  final String? accountId;
  final String? deviceId;
  final bool firstSyncDone;
  final int? lastSyncAt;

  bool get isPaired => accountId != null;

  SyncState copyWith({
    int? schemaVersion,
    Object? accountId = _unset,
    Object? deviceId = _unset,
    bool? firstSyncDone,
    Object? lastSyncAt = _unset,
  }) {
    return SyncState(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      accountId: accountId == _unset ? this.accountId : accountId as String?,
      deviceId: deviceId == _unset ? this.deviceId : deviceId as String?,
      firstSyncDone: firstSyncDone ?? this.firstSyncDone,
      lastSyncAt: lastSyncAt == _unset ? this.lastSyncAt : lastSyncAt as int?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'accountId': accountId,
        'deviceId': deviceId,
        'firstSyncDone': firstSyncDone,
        'lastSyncAt': lastSyncAt,
      };

  static SyncState fromJson(Map<String, dynamic> json) {
    return SyncState(
      schemaVersion: json['schemaVersion'] is int
          ? json['schemaVersion'] as int
          : currentSchemaVersion,
      accountId: json['accountId'] is String ? json['accountId'] as String : null,
      deviceId: json['deviceId'] is String ? json['deviceId'] as String : null,
      firstSyncDone: json['firstSyncDone'] == true,
      lastSyncAt: json['lastSyncAt'] is int ? json['lastSyncAt'] as int : null,
    );
  }

  String toCanonicalText() => Canonical.documentText(toJson());
}

/// 视图偏好（ADR-059）：**不参与同步**，因此不放进实体模型。
class UiPrefs {
  const UiPrefs({this.collapsedIds = const <String>{}, this.lastOpenedDoc});

  static const UiPrefs empty = UiPrefs();

  final Set<String> collapsedIds;
  final DocName? lastOpenedDoc;

  bool isCollapsed(String id) => collapsedIds.contains(id);

  UiPrefs toggleCollapsed(String id, bool collapsed) {
    final next = Set<String>.from(collapsedIds);
    if (collapsed) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return UiPrefs(collapsedIds: next, lastOpenedDoc: lastOpenedDoc);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'collapsedIds': collapsedIds.toList(growable: false)..sort(),
        'lastOpenedDoc': lastOpenedDoc?.fileName,
      };

  static UiPrefs fromJson(Map<String, dynamic> json) {
    final raw = json['collapsedIds'];
    final collapsed = <String>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is String) collapsed.add(item);
      }
    }
    final last = json['lastOpenedDoc'];
    return UiPrefs(
      collapsedIds: collapsed,
      lastOpenedDoc: last is String ? DocName.fromFileName(last) : null,
    );
  }

  String toCanonicalText() => Canonical.documentText(toJson());
}

const Object _unset = Object();
