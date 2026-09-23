import '../json/canonical.dart';
import '../models/enums.dart';

/// 界面偏好（**不是数据**）：折叠状态、上次打开的页签等。
///
/// 单独成文件的原因：这类改动很频繁（点一下折叠就变），
/// 不值得为它重写整份数据文件。
class UiPrefs {
  const UiPrefs({
    this.collapsedIds = const <String>{},
    this.lastTabIndex = 0,
    this.compactTaskView = false,
    this.lastExportedAt,
  });

  static const UiPrefs empty = UiPrefs();

  /// 已折叠的节点 id（项目树 / 任务线共用）
  final Set<String> collapsedIds;

  /// 上次停留的底部页签
  final int lastTabIndex;

  /// 任务线是否使用紧凑模式（手机上默认更紧凑）
  final bool compactTaskView;

  /// 上次成功导出的时间戳；`null` 表示从未导出。
  ///
  /// 没有云端时导出是唯一的"离开这台手机"的通道，所以要能提醒用户该导出了。
  final int? lastExportedAt;

  bool isCollapsed(String id) => collapsedIds.contains(id);

  UiPrefs toggleCollapsed(String id, bool collapsed) {
    final next = Set<String>.from(collapsedIds);
    if (collapsed) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return UiPrefs(
      collapsedIds: next,
      lastTabIndex: lastTabIndex,
      compactTaskView: compactTaskView,
      lastExportedAt: lastExportedAt,
    );
  }

  UiPrefs copyWith({
    Set<String>? collapsedIds,
    int? lastTabIndex,
    bool? compactTaskView,
    Object? lastExportedAt = _unset,
  }) =>
      UiPrefs(
        collapsedIds: collapsedIds ?? this.collapsedIds,
        lastTabIndex: lastTabIndex ?? this.lastTabIndex,
        compactTaskView: compactTaskView ?? this.compactTaskView,
        lastExportedAt:
            lastExportedAt == _unset ? this.lastExportedAt : lastExportedAt as int?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'collapsedIds': collapsedIds.toList(growable: false)..sort(),
        'lastTabIndex': lastTabIndex,
        'compactTaskView': compactTaskView,
        'lastExportedAt': lastExportedAt,
      };

  static UiPrefs fromJson(Map<String, dynamic> json) {
    final raw = json['collapsedIds'];
    final collapsed = <String>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is String) collapsed.add(item);
      }
    }
    return UiPrefs(
      collapsedIds: collapsed,
      lastTabIndex: json['lastTabIndex'] is int ? json['lastTabIndex'] as int : 0,
      compactTaskView: json['compactTaskView'] == true,
      lastExportedAt: json['lastExportedAt'] is int ? json['lastExportedAt'] as int : null,
    );
  }

  String toCanonicalText() => Canonical.documentText(toJson());

  /// 便于设置页显示"上次打开的页签"（枚举顺序与 DocName 无关，仅供展示）。
  static String describeTab(int index) {
    const labels = <String>['灵感', '项目', '事件', '更多'];
    if (index < 0 || index >= labels.length) return labels.first;
    return labels[index];
  }

  /// 未使用但保留：枚举 → 集合名（供将来把偏好扩展到"上次打开的集合"）。
  static String collectionLabel(DocName name) => name.key;
}

const Object _unset = Object();
