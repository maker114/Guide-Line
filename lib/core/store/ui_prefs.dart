import '../json/canonical.dart';
import '../models/reminder.dart';

/// 界面偏好（**不是数据**）：折叠状态、外观、上次打开的页签等。
///
/// 单独成文件的原因：这类改动很频繁（点一下折叠就变），
/// 不值得为它重写整份数据文件；而且这些偏好丢了也无所谓，损坏时直接重置。
class UiPrefs {
  const UiPrefs({
    this.collapsedIds = const <String>{},
    this.expandedIds = const <String>{},
    this.lastTabIndex = 0,
    this.compactTaskView = false,
    this.lastExportedAt,
    this.themeId = defaultThemeId,
    this.themeMode = defaultThemeMode,
    this.backgroundImagePath,
    this.backgroundOpacity = defaultBackgroundOpacity,
    this.backgroundBlur = 0,
    this.backgroundSeedHex,
    this.aiBaseUrl = defaultAiBaseUrl,
    this.aiModel = defaultAiModel,
    this.aiEnabled = true,
    this.emptyBoxSeed,
    this.githubBackupEnabled = false,
    this.githubBackupOwner = '',
    this.githubBackupRepo = '',
    this.githubBackupBranch = defaultGithubBranch,
    this.githubBackupPath = defaultGithubBackupPath,
    this.reminderEnabled = false,
    this.reminderLeads = ReminderLead.defaults,
  });

  static const UiPrefs empty = UiPrefs();

  /// 默认主题 id（与 `lib/ui/theme/app_theme.dart` 里的预设表对应）。
  ///
  /// 这里放一个字面量而不是 import 主题表：core 层是纯 Dart，不认识 Flutter 的 `Color`。
  static const String defaultThemeId = 'default';

  /// 深色 / 亮色的三种取法：**跟系统 / 只要亮色 / 只要深色**。
  ///
  /// 存字符串而不是 Dart `enum`：这个字段进出的是**偏好文件**（`ui_prefs.json`），
  /// 契约上它与 `themeId` 同一档 —— 都是"面向上层的一段标识"，不是数据层枚举。
  /// 界面侧在 `main.dart` 里把它翻成 `ThemeMode`，core 层不认识 Flutter。
  static const String themeModeSystem = 'system';
  static const String themeModeLight = 'light';
  static const String themeModeDark = 'dark';

  /// 三种取法的全集（界面按它排选项，免得两边各写一份）。
  static const List<String> themeModes = <String>[
    themeModeSystem,
    themeModeLight,
    themeModeDark,
  ];

  /// 默认：**跟随系统**。
  ///
  /// 选它当默认值是为了老偏好文件：主题模式是新加的字段，老文件里没有这个键，
  /// 读进来必须落到与从前**完全一样**的行为上（从前没给 `MaterialApp.themeMode`，
  /// 那就是跟系统）。
  static const String defaultThemeMode = themeModeSystem;

  /// 背景图默认不透明度：够看出图，又不影响读正文。
  static const double defaultBackgroundOpacity = 0.30;

  /// AI 接口地址默认值。
  ///
  /// 与 `AiConfig.defaultBaseUrl` 是同一个值，但这里再写一份字面量：
  /// **core 不认识平台层**，而这份是"偏好文件里存什么"的默认值。
  static const String defaultAiBaseUrl = 'https://api.deepseek.com';

  /// AI 模型默认名。
  ///
  /// 是 `deepseek-flash` 而不是 `deepseek-v4.1-flash` ——
  /// 官方发布说明写的是"将模型名称更改为 `deepseek-flash`"。
  static const String defaultAiModel = 'deepseek-flash';

  /// GitHub 备份同步的默认分支。
  ///
  /// 与 `GitHubBackupConfig.defaultBranch` 是同一个值，但这里再写一份字面量：
  /// **core 的偏好文件不认识平台层**（与 [defaultAiBaseUrl] 同一条理由）。
  static const String defaultGithubBranch = 'main';

  /// GitHub 备份同步的默认远程路径。
  ///
  /// 与 `GitHubBackupConfig.defaultPath` 同值同理由。
  static const String defaultGithubBackupPath = 'backups/guideline-latest.json.gz';

  /// 已折叠的节点 id（项目树 / 任务线共用）
  final Set<String> collapsedIds;

  /// **被显式展开过**的节点 id。
  ///
  /// 为什么需要两个集合：折叠的"默认值"是算出来的 ——
  /// 未完成的默认展开、已完成的默认收起（所以「已完成任务自动折叠」不需要
  /// 在状态变化时去改偏好）。但用户手动展开一个已完成任务后，这个选择必须留得住，
  /// 否则它下次又会自己缩回去。显式展开优先于显式收起，两者都没有才用默认值。
  final Set<String> expandedIds;

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

  /// 深色 / 亮色怎么取；取值为 [themeModes] 之一。
  ///
  /// 与 [themeId] 是两个互不相干的维度：那个决定**用哪套配色**，
  /// 这个决定**用它的亮色还是深色**。四个组合都成立。
  final String themeMode;

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

  /// AI 接口地址（**非敏感**）。**apiKey 不在这里** ——
  /// 那个走 `flutter_secure_storage`，因为这个文件会进滚动备份与整库导出。
  final String aiBaseUrl;

  /// AI 模型名（**非敏感**，允许自定义以兼容其它 OpenAI 兼容端点）。
  final String aiModel;

  /// AI 整理功能的**总开关**（默认开）。
  ///
  /// 关掉之后，界面上凡是"AI 整理"的入口都不再出现（清单里的那一条、以及
  /// 相关提示），但**已经填好的地址 / 模型 / Key 一个都不清**：
  /// 开关只决定"显不显示"，不决定"记不记得住"。`apiKey` 本来就在安全存储里，
  /// 与这个字段无关。
  final bool aiEnabled;

  /// 灵感箱空态那句轮换文案的**抽签种子**（`null` = 还没抽过）。
  ///
  /// 「随机展示」选的是**每次启动抽一次、本次会话固定**（ADR-084）：
  /// 抽签结果存进偏好，所以同一个会话里切页签 / 重建 / 返回都不会变，
  /// 下次启动才重抽。存种子而不是存那一句话 —— 文案表改了之后老偏好
  /// 会自然落到新表上，不会留着一句已经从代码里删掉的话。
  final int? emptyBoxSeed;

  /// GitHub 备份同步的**总开关**（默认**关**）。
  ///
  /// 与 [aiEnabled] 同一条口径：开关只决定"显不显示 / 能不能用"，
  /// 不决定"记不记得住" —— 关掉不清 owner / repo / Token，也不删远程那份。
  /// 默认关是因为它会把**整份数据**发到手机之外，而 AI 只发一个项目的清单。
  final bool githubBackupEnabled;

  /// GitHub 仓库所有者（**非敏感**）。
  ///
  /// Token **不在这里** —— 那个走 `flutter_secure_storage`，
  /// 因为这个文件会进滚动备份与整库导出（与 [aiBaseUrl] 同一条理由）。
  final String githubBackupOwner;

  /// GitHub 仓库名（**非敏感**）。
  final String githubBackupRepo;

  /// GitHub 分支名（**非敏感**）。
  final String githubBackupBranch;

  /// 远程文件路径（**非敏感**）。
  final String githubBackupPath;

  /// 提醒功能的**总开关**（默认**关**，用户 2026-10-03 定）。
  ///
  /// 默认关的两个理由：
  ///   1. 与 README「没有账号、没有服务器、**没有推送**」那句既有承诺一致 ——
  ///      装完就自己弹东西，是用户没答应过的事；
  ///   2. 开着才需要申请系统通知权限，而默认开就意味着装完第一件事就是弹权限框。
  ///
  /// 关掉只停"排期"，**不清** [reminderLeads] 里配好的两档 ——
  /// 与 [aiEnabled] / [githubBackupEnabled] 同一条口径。
  final bool reminderEnabled;

  /// 两档提前量，**长度恒为 [ReminderLead.slotCount]**（缺键 / 坏值 / 多写都会
  /// 被 [ReminderLead.normalize] 整成两档）。
  ///
  /// 为什么与"界面偏好"放一起：它绑的是**这一台设备的通知行为**，
  /// 所以按现状口径它**不进导出、不进备份**（`ui_prefs.json` 本来就不进），
  /// 换台设备带过去只会得到一个"开着但没权限"的假象。
  final List<ReminderLead> reminderLeads;

  bool get hasBackground => backgroundImagePath != null && backgroundImagePath!.isNotEmpty;

  /// 节点是否展开：显式展开 > 显式收起 > [defaultExpanded]。
  bool isExpanded(String id, {bool defaultExpanded = true}) {
    if (expandedIds.contains(id)) return true;
    if (collapsedIds.contains(id)) return false;
    return defaultExpanded;
  }

  /// 记录一次显式展开 / 收起，并把该 id 从另一个集合里清掉（两者互斥）。
  UiPrefs withExpanded(String id, {required bool expanded}) {
    final collapsed = Set<String>.from(collapsedIds);
    final expandedSet = Set<String>.from(expandedIds);
    if (expanded) {
      expandedSet.add(id);
      collapsed.remove(id);
    } else {
      collapsed.add(id);
      expandedSet.remove(id);
    }
    return copyWith(collapsedIds: collapsed, expandedIds: expandedSet);
  }

  UiPrefs copyWith({
    Set<String>? collapsedIds,
    Set<String>? expandedIds,
    int? lastTabIndex,
    bool? compactTaskView,
    Object? lastExportedAt = _unset,
    String? themeId,
    String? themeMode,
    Object? backgroundImagePath = _unset,
    double? backgroundOpacity,
    double? backgroundBlur,
    Object? backgroundSeedHex = _unset,
    String? aiBaseUrl,
    String? aiModel,
    bool? aiEnabled,
    Object? emptyBoxSeed = _unset,
    bool? githubBackupEnabled,
    String? githubBackupOwner,
    String? githubBackupRepo,
    String? githubBackupBranch,
    String? githubBackupPath,
    bool? reminderEnabled,
    List<ReminderLead>? reminderLeads,
  }) =>
      UiPrefs(
        collapsedIds: collapsedIds ?? this.collapsedIds,
        expandedIds: expandedIds ?? this.expandedIds,
        lastTabIndex: lastTabIndex ?? this.lastTabIndex,
        compactTaskView: compactTaskView ?? this.compactTaskView,
        lastExportedAt:
            lastExportedAt == _unset ? this.lastExportedAt : lastExportedAt as int?,
        themeId: themeId ?? this.themeId,
        themeMode: themeMode ?? this.themeMode,
        backgroundImagePath: backgroundImagePath == _unset
            ? this.backgroundImagePath
            : backgroundImagePath as String?,
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        backgroundBlur: backgroundBlur ?? this.backgroundBlur,
        backgroundSeedHex: backgroundSeedHex == _unset
            ? this.backgroundSeedHex
            : backgroundSeedHex as String?,
        aiBaseUrl: aiBaseUrl ?? this.aiBaseUrl,
        aiModel: aiModel ?? this.aiModel,
        aiEnabled: aiEnabled ?? this.aiEnabled,
        emptyBoxSeed:
            emptyBoxSeed == _unset ? this.emptyBoxSeed : emptyBoxSeed as int?,
        githubBackupEnabled: githubBackupEnabled ?? this.githubBackupEnabled,
        githubBackupOwner: githubBackupOwner ?? this.githubBackupOwner,
        githubBackupRepo: githubBackupRepo ?? this.githubBackupRepo,
        githubBackupBranch: githubBackupBranch ?? this.githubBackupBranch,
        githubBackupPath: githubBackupPath ?? this.githubBackupPath,
        reminderEnabled: reminderEnabled ?? this.reminderEnabled,
        reminderLeads: reminderLeads ?? this.reminderLeads,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'collapsedIds': collapsedIds.toList(growable: false)..sort(),
        'expandedIds': expandedIds.toList(growable: false)..sort(),
        'lastTabIndex': lastTabIndex,
        'compactTaskView': compactTaskView,
        'lastExportedAt': lastExportedAt,
        'themeId': themeId,
        'themeMode': themeMode,
        'backgroundImagePath': backgroundImagePath,
        'backgroundOpacity': backgroundOpacity,
        'backgroundBlur': backgroundBlur,
        'backgroundSeedHex': backgroundSeedHex,
        'aiBaseUrl': aiBaseUrl,
        'aiModel': aiModel,
        'aiEnabled': aiEnabled,
        'emptyBoxSeed': emptyBoxSeed,
        'githubBackupEnabled': githubBackupEnabled,
        'githubBackupOwner': githubBackupOwner,
        'githubBackupRepo': githubBackupRepo,
        'githubBackupBranch': githubBackupBranch,
        'githubBackupPath': githubBackupPath,
        'reminderEnabled': reminderEnabled,
        'reminderLeads': reminderLeads
            .map((lead) => lead.toJson())
            .toList(growable: false),
      };

  static UiPrefs fromJson(Map<String, dynamic> json) {
    final collapsed = _readIdSet(json['collapsedIds']);
    final expanded = _readIdSet(json['expandedIds']);
    final themeId = json['themeId'];
    final backgroundPath = json['backgroundImagePath'];
    return UiPrefs(
      collapsedIds: collapsed,
      expandedIds: expanded,
      lastTabIndex: json['lastTabIndex'] is int ? json['lastTabIndex'] as int : 0,
      compactTaskView: json['compactTaskView'] == true,
      lastExportedAt: json['lastExportedAt'] is int ? json['lastExportedAt'] as int : null,
      themeId: themeId is String && themeId.isNotEmpty ? themeId : defaultThemeId,
      // 坏值 / 老文件里没有这个键 → 收回"跟随系统"，与从前的行为一致
      themeMode: _readThemeMode(json['themeMode']),
      backgroundImagePath:
          backgroundPath is String && backgroundPath.isNotEmpty ? backgroundPath : null,
      backgroundOpacity: _readUnitDouble(json['backgroundOpacity'], defaultBackgroundOpacity),
      backgroundBlur: _readNonNegativeDouble(json['backgroundBlur'], 0),
      backgroundSeedHex: _readHex(json['backgroundSeedHex']),
      // 坏值（空串 / 非字符串）收回默认值，与其它偏好字段同一套口径
      aiBaseUrl: _readNonEmpty(json['aiBaseUrl'], defaultAiBaseUrl),
      aiModel: _readNonEmpty(json['aiModel'], defaultAiModel),
      // 老偏好文件里没有这个键 → 保持默认开（加了开关不该把功能悄悄关掉）
      aiEnabled: json['aiEnabled'] != false,
      // 老偏好文件里没有这个键 → `null`，界面首帧自己抽一次
      emptyBoxSeed: json['emptyBoxSeed'] is int ? json['emptyBoxSeed'] as int : null,
      // GitHub 备份同步：与 AI 那几项同一套"坏值 / 缺键静默回默认"的口径。
      // 开关刻意**缺键即关**：它会把整份数据发到手机之外，不该继承一个"默认开"。
      githubBackupEnabled: json['githubBackupEnabled'] == true,
      githubBackupOwner: _readTrimmed(json['githubBackupOwner']),
      githubBackupRepo: _readTrimmed(json['githubBackupRepo']),
      githubBackupBranch: _readNonEmpty(json['githubBackupBranch'], defaultGithubBranch),
      githubBackupPath: _readNonEmpty(json['githubBackupPath'], defaultGithubBackupPath),
      // 提醒：开关**缺键即关**（与 githubBackupEnabled 同一条口径 ——
      // 老偏好文件里没有它，不该因此凭空开始弹通知）；
      // 两档缺键则取默认的 60 / 10 分钟，这样用户一打开开关就有可用的默认，
      // 而不是先看到两格空白。
      reminderEnabled: json['reminderEnabled'] == true,
      reminderLeads: ReminderLead.normalize(json['reminderLeads']),
    );
  }

  /// 读一个"允许为空串"的文本偏好（空串是有意义的值：还没填）。
  static String _readTrimmed(Object? value) => value is String ? value.trim() : '';

  /// 读主题模式：只认 [themeModes] 里那三个字面量，别的（含缺键、类型不对）一律
  /// 收回默认值。与其它偏好字段同一套"坏值不抛、静默回默认"的口径。
  static String _readThemeMode(Object? value) =>
      value is String && themeModes.contains(value) ? value : defaultThemeMode;

  static String _readNonEmpty(Object? value, String fallback) {
    if (value is! String) return fallback;
    final trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static String? _readHex(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.length != 7 || !trimmed.startsWith('#')) return null;
    return trimmed.toLowerCase();
  }

  static Set<String> _readIdSet(Object? raw) {
    final out = <String>{};
    if (raw is List) {
      for (final item in raw) {
        if (item is String && item.isNotEmpty) out.add(item);
      }
    }
    return out;
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
}

const Object _unset = Object();
