import '../json/canonical.dart';
import '../models/enums.dart';

/// 界面偏好（**不是数据**）：折叠状态、外观、上次打开的页签等。
///
/// 单独成文件的原因：这类改动很频繁（点一下折叠就变），
/// 不值得为它重写整份数据文件；而且这些偏好丢了也无所谓，损坏时直接重置。
class UiPrefs {
  const UiPrefs({
    this.collapsedIds = const <String>{},
    this.lastTabIndex = 0,
    this.compactTaskView = false,
    this.lastExportedAt,
    this.themeId = defaultThemeId,
    this.backgroundImagePath,
    this.backgroundOpacity = defaultBackgroundOpacity,
    this.backgroundBlur = 0,
    this.backgroundSeedHex,
  });

  static const UiPrefs empty = UiPrefs();

  /// 默认主题 id（与 `lib/ui/theme/app_theme.dart` 里的预设表对应）。
  ///
  /// 这里放一个字面量而不是 import 主题表：core 层是纯 Dart，不认识 Flutter 的 `Color`。
  static const String defaultThemeId = 'default';

  /// 背景图默认不透明度：够看出图，又不影响读正文。
  static const double defaultBackgroundOpacity = 0.30;

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

  /// 主题 id；`follow-background` 表示"跟随背景图取色"。
  final String themeId;

  /// 背景图在应用私有目录里的路径；`null` 表示没有背景图。
  final String? backgroundImagePath;

  /// 背景图不透明度 0..1。
  final double backgroundOpacity;

  /// 背景图模糊半径（逻辑像素），0 表示不模糊。
  final double backgroundBlur;

  /// 从背景图取到的主色（`#RRGGBB`，小写）。
  ///
  /// 存下来是为了**不必每次启动都重新解码图片**（"跟随背景图"主题要同步拿到颜色）。
  final String? backgroundSeedHex;

  bool get hasBackground => backgroundImagePath != null && backgroundImagePath!.isNotEmpty;

  bool isCollapsed(String id) => collapsedIds.contains(id);

  UiPrefs toggleCollapsed(String id, bool collapsed) {
    final next = Set<String>.from(collapsedIds);
    if (collapsed) {
      next.add(id);
    } else {
      next.remove(id);
    }
    return copyWith(collapsedIds: next);
  }

  UiPrefs copyWith({
    Set<String>? collapsedIds,
    int? lastTabIndex,
    bool? compactTaskView,
    Object? lastExportedAt = _unset,
    String? themeId,
    Object? backgroundImagePath = _unset,
    double? backgroundOpacity,
    double? backgroundBlur,
    Object? backgroundSeedHex = _unset,
  }) =>
      UiPrefs(
        collapsedIds: collapsedIds ?? this.collapsedIds,
        lastTabIndex: lastTabIndex ?? this.lastTabIndex,
        compactTaskView: compactTaskView ?? this.compactTaskView,
        lastExportedAt:
            lastExportedAt == _unset ? this.lastExportedAt : lastExportedAt as int?,
        themeId: themeId ?? this.themeId,
        backgroundImagePath: backgroundImagePath == _unset
            ? this.backgroundImagePath
            : backgroundImagePath as String?,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        backgroundBlur: backgroundBlur ?? this.backgroundBlur,
        backgroundSeedHex: backgroundSeedHex == _unset
            ? this.backgroundSeedHex
            : backgroundSeedHex as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'collapsedIds': collapsedIds.toList(growable: false)..sort(),
        'lastTabIndex': lastTabIndex,
        'compactTaskView': compactTaskView,
        'lastExportedAt': lastExportedAt,
        'themeId': themeId,
        'backgroundImagePath': backgroundImagePath,
        'backgroundOpacity': backgroundOpacity,
        'backgroundBlur': backgroundBlur,
        'backgroundSeedHex': backgroundSeedHex,
      };

  static UiPrefs fromJson(Map<String, dynamic> json) {
    final raw = json['collapsedIds'];
    final collapsed = <String>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is String) collapsed.add(item);
      }
    }
    final themeId = json['themeId'];
    final backgroundPath = json['backgroundImagePath'];
    return UiPrefs(
      collapsedIds: collapsed,
      lastTabIndex: json['lastTabIndex'] is int ? json['lastTabIndex'] as int : 0,
      compactTaskView: json['compactTaskView'] == true,
      lastExportedAt: json['lastExportedAt'] is int ? json['lastExportedAt'] as int : null,
      themeId: themeId is String && themeId.isNotEmpty ? themeId : defaultThemeId,
      backgroundImagePath:
          backgroundPath is String && backgroundPath.isNotEmpty ? backgroundPath : null,
      backgroundOpacity: _readUnitDouble(json['backgroundOpacity'], defaultBackgroundOpacity),
      backgroundBlur: _readNonNegativeDouble(json['backgroundBlur'], 0),
      backgroundSeedHex: _readHex(json['backgroundSeedHex']),
    );
  }

  static String? _readHex(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.length != 7 || !trimmed.startsWith('#')) return null;
    return trimmed.toLowerCase();
  }

  static double _readUnitDouble(Object? value, double fallback) {
    if (value is! num) return fallback;
    final v = value.toDouble();
    if (v.isNaN) return fallback;
    return v.clamp(0.0, 1.0);
  }

  static double _readNonNegativeDouble(Object? value, double fallback) {
    if (value is! num) return fallback;
    final v = value.toDouble();
    if (v.isNaN || v < 0) return fallback;
    return v;
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
