import '../json/canonical.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import '../models/enums.dart';
import 'export_codec.dart';
import 'store_diff.dart';

/// GitHub 备份同步的**纯 Dart 判定内核**。
///
/// 这一层刻意不知道 HTTP 长什么样：它只回答一个问题 ——
/// "手上这两份（本地 / 远程）+ 上次同步的记账，现在该做什么、该说什么"。
/// 于是冲突判定能被纯 Dart 测出来，不必起一台假服务器。
///
/// 一条贯穿全篇的口径（与 `AppStorage._recordCountOf` 同一套判据）：
/// **一条活记录都没有的备份不算可用备份**。空文件是"备份"这句话在
/// 数据安全上是反的 —— 拿它覆盖本地等于静默清空。
///
/// 冲突口径按 ADR-088 钉死：两边都改过时**只判定、不合并** ——
/// [analyzeSync] 返回 [SyncAction.bothChanged]，由界面让用户手动三选一。

/// 同步判定出来的动作。
enum SyncAction {
  /// 远程什么都没有，或者上一次两边是一致的而本地又改了 → 推上去。
  push,

  /// 远程比本地新（或本地压根没数据）→ 拉下来。
  pull,

  /// 两边最后改于同一刻 → 什么都不用做。
  noChange,

  /// 两边都改过 → **不替用户决定**，只把情况摆出来让他手动二选一。
  bothChanged,

  /// 本地一条活记录都没有 —— 推上去等于用空数据覆盖远程那份。
  localEmpty,
}

/// 一次同步判定的结果。
class SyncPlan {
  const SyncPlan({
    required this.action,
    required this.message,
    this.localSavedAt,
    this.remoteSavedAt,
    this.trustedOverwrite = false,
  });

  final SyncAction action;

  /// 可以直接显示给用户的中文说明（含两边的时间与条数）。
  final String message;

  /// 本地那一份的最后修改时间（没有数据时为 null）。
  final int? localSavedAt;

  /// 远程那一份的最后修改时间（没有这份文件时为 null）。
  final int? remoteSavedAt;

  /// 这一趟是**可信覆盖**：云端的提交码跟上次成功同步记下的那一个一字不差，
  /// 说明这中间没有第三方动过云端 —— 于是本地直接覆盖它，不必再摆差异面板
  /// （需求④ / ADR-093）。
  ///
  /// 与 [needsExtraConfirm] 是两码事：那个管"本地是空的、别把云端擦掉"，这个管
  /// "这一趟不用问"。判据只看提交码，**不看时间戳** —— 换台设备改过云端时，
  /// 时间戳可能还不如本地新，只有提交码能回答"是不是同一次上传"（ADR-089）。
  final bool trustedOverwrite;

  /// 推送之前需不需要用户额外确认一次。
  ///
  /// 只有一种情况：**本地是空的而远程有东西** —— 那不叫"备份"，
  /// 叫"把远程那份擦掉"，必须单独拦一道。
  bool get needsExtraConfirm => action == SyncAction.localEmpty;
}

/// 上次成功同步的记账。
///
/// 它**不是数据**：与 `implementation_history.json` / `reset_snapshot.json`
/// 同一个性质 —— 不进主数据文件、不进整库导出、不进滚动备份。
/// 丢了只会让下一次判定退化成"两边都比对不出来"，最坏是让用户手动选一次，
/// 不会影响任何一条真实记录。
class SyncRecord {
  const SyncRecord({
    required this.syncedAt,
    required this.remoteSha,
    required this.recordCount,
    this.commitSha = '',
    this.offlineWarnedOn = '',
  });

  /// 上次成功同步的时刻（毫秒）。
  final int syncedAt;

  /// 上次写入 / 读到的远程文件 sha。
  final String remoteSha;

  /// 上次同步时两边一致的那一份里有几条活记录。
  final int recordCount;

  /// 上次同步对应的**提交码**（`1.8.5` 及以前的记账没有这一项，读出来是空串）。
  ///
  /// 空串的含义是**未知**，不是"不一致" —— 老记账文件缺这个字段只说明
  /// "那时还没记"，不能让一次正常的同步被说成双端版本对不上。
  final String commitSha;

  /// 「GitHub 未连接」那条警告**当天已经弹过一次**的日期（`YYYY-MM-DD`）。
  ///
  /// 空串 = 还没弹过。需求⑤要的是"连不上就警告"，而每次启动都弹一遍在断网的
  /// 日子里会变成噪音，所以按天记账（ADR-093）。它与 [commitSha] 同一个性质：
  /// **丢了不影响任何一条真实记录**，最坏是当天多弹一次。
  final String offlineWarnedOn;

  /// 有没有可用的记账。
  static SyncRecord? parse(String? text) {
    if (text == null) return null;
    try {
      final root = Canonical.decode(text);
      if (root is! Map) return null;
      final syncedAt = root['syncedAt'];
      final sha = root['remoteSha'];
      final count = root['recordCount'];
      if (syncedAt is! int || sha is! String || count is! int) return null;
      if (sha.isEmpty || syncedAt <= 0 || count < 0) return null;
      final commit = root['commitSha'];
      final warned = root['offlineWarnedOn'];
      return SyncRecord(
        syncedAt: syncedAt,
        remoteSha: sha,
        recordCount: count,
        commitSha: commit is String ? commit : '',
        offlineWarnedOn: warned is String ? warned : '',
      );
    } catch (_) {
      // 记账坏了就当没有：它只影响"能不能自动判断"，不影响任何真实数据。
      return null;
    }
  }

  String toCanonicalText() => Canonical.documentText(<String, dynamic>{
        'syncedAt': syncedAt,
        'remoteSha': remoteSha,
        'recordCount': recordCount,
        // 未知就不写出去：与"空值不写出"的契约口径一致。
        if (commitSha.isNotEmpty) 'commitSha': commitSha,
        if (offlineWarnedOn.isNotEmpty) 'offlineWarnedOn': offlineWarnedOn,
      });

  SyncRecord copyWith({
    int? syncedAt,
    String? remoteSha,
    int? recordCount,
    String? commitSha,
    String? offlineWarnedOn,
  }) =>
      SyncRecord(
        syncedAt: syncedAt ?? this.syncedAt,
        remoteSha: remoteSha ?? this.remoteSha,
        recordCount: recordCount ?? this.recordCount,
        commitSha: commitSha ?? this.commitSha,
        offlineWarnedOn: offlineWarnedOn ?? this.offlineWarnedOn,
      );
}

/// 远程那一份备份（**已经解出来**的形态）。
class RemoteBackup {
  const RemoteBackup({
    required this.path,
    required this.sha,
    required this.bytes,
    required this.payload,
    this.commitSha = '',
  });

  /// 仓库里的路径。
  final String path;

  /// GitHub 给的 blob sha —— 覆盖它必须带上这个值。
  final String sha;

  /// 写成功时 GitHub 顺手回来的**提交码**；**读回来的那一份不知道**（空串）。
  ///
  /// 它与 [sha] 不是一回事，别混用：`sha` 答"内容一不一样"，
  /// 提交码答"是不是**同一次上传**" —— 推送两次、内容一个字没改，
  /// 提交码也不同。要在两台手机之间确认"我们看到的是同一次上传"，
  /// 靠的是后者。空串一律当**未知**，不许当成"不一致"。
  final String commitSha;

  /// 远程文件的原始字节（拉取失败时用它落一份导出存档）。
  final List<int> bytes;

  /// 解出来的内容；`null` 表示这份文件读不出 Guide Line 数据。
  final ExportPayload? payload;

  /// 从远程字节解析一份。
  factory RemoteBackup.fromBytes({
    required String path,
    required String sha,
    required List<int> bytes,
    String commitSha = '',
  }) {
    final issues = DecodeIssues();
    final payload = ExportCodec.decode(bytes, issues);
    return RemoteBackup(
      path: path,
      sha: sha,
      bytes: bytes,
      payload: payload.readable ? payload : null,
      commitSha: commitSha,
    );
  }

  /// 这份文件能不能当备份用。
  bool get readable => payload != null;

  /// 远程那一份里的**活记录**条数（不含墓碑；读不出时为 0）。
  int get recordCount => payload == null ? 0 : liveRecordCount(payload!.store);

  /// 远程那一份的最后修改时间（读不出时为 null）。
  int? get savedAt => payload?.exportedAt;

  /// 它算不算一份**可用**备份（判据与本地备份那一套同一句话）。
  bool get usable => readable && recordCount > 0;
}

/// 远程仓库里**那一次提交**（只有元数据，不含文件内容）。
///
/// 存在的理由只有一个：**提交码是双端判断"是不是同一次上传"的凭证**（ADR-089）。
/// 内容码（[RemoteBackup.sha]）答"内容一不一样"，而"两台手机上内容碰巧
/// 一样"并不说明它们来自同一次上传 —— 只有提交码能说明。
class RemoteCommit {
  const RemoteCommit({
    required this.sha,
    this.message = '',
    this.committedAt,
  });

  /// 提交码（GitHub 给的是完整 40 位）；读不到时是**空串**，当"未知"。
  final String sha;

  /// 提交说明的首行（我们推上去时写的是 `backup: GuideLine …`）。
  final String message;

  /// 提交时刻（毫秒）；读不到时为 null。
  final int? committedAt;

  /// 有没有读到提交码。
  bool get known => sha.isNotEmpty;
}

/// 把提交码 / 内容码缩成前 7 位（git 的惯例），空串写「未知」。
///
/// 单独一个函数是为了让界面与控制器的说法**只有一处**：
/// 两处各写一遍 `substring(0, 7)`，早晚会在某处长成 8 位。
String shortSha(String sha) {
  if (sha.isEmpty) return '未知';
  return sha.length <= 7 ? sha : sha.substring(0, 7);
}

/// 云端此刻的提交码，跟上一次成功同步记下的那一个**对得上**吗（需求④）。
///
/// "对得上"的严格含义是**两侧都非空且一字相等**。三种看着像、其实都不算的情形：
///   · 老记账里没有 `commitSha`（1.8.5 及以前建的）→ 未知，不能说成"没被改过"；
///   · 这一次没读到提交码（网络半通 / 仓库刚建 / 分支名写错）→ 同样未知；
///   · 两边都是空串 → 空串在这里是"不知道"，不是"两边一样"。
/// 只有真的对得上，才敢把"本地无条件覆盖云端"放出去（ADR-093）。
bool commitCodeMatches({String? remoteCommitSha, String? lastSyncedCommitSha}) {
  final remote = remoteCommitSha ?? '';
  final last = lastSyncedCommitSha ?? '';
  if (remote.isEmpty || last.isEmpty) return false;
  return remote == last;
}

/// 一个错自己声明的"我是不是网络问题"。
///
/// 平台层的 `GitHubBackupException` 通过 `implements` 实现它 —— `looksOffline`
/// 于是既能问到那个标记，又不必把平台层 import 进来（分层硬线）。
abstract interface class GitHubBackupNetworkError {
  /// true = 连不上 / 超时 / 请求被中断；false = Token、权限、地址、体积这类。
  bool get isNetworkFailure;
}

/// 这句错是不是"连不上 GitHub"（需求⑤：连不上要单独给一句警告 + 一枚常驻胶囊，
/// 跟"这次真的失败了"分开说）。
///
/// **判据是抛错方自己标的那个标记**（[GitHubBackupNetworkError.isNetworkFailure]，
/// 平台层那个异常类实现的就是它），不是拿中文去比对消息（ADR-095）：
/// 以前这里认的是"连不上 / 网络请求失败 / 请求超时"三个中文串，文案改一个词就
/// 静默失配 —— 离线会被说成"这次真的失败"，用户于是去改 Token、改仓库名，
/// 而真正该做的是看一眼网络。
///
/// 参数写成 `Object?` 而不是那个异常类型，是为了**不 import 平台层**
/// （`lib/core` 不许依赖 `lib/platform`，由 `test/core/architecture_test.dart` 守着）：
/// 这里只问"你有没有说自己 network: true"。没实现这个接口的东西（自己写的配置
/// 错误、GitHub 的 4xx/5xx，以及随手传进来的消息串）一律算失败。
bool looksOffline(Object? error) => switch (error) {
      final GitHubBackupNetworkError failure => failure.isNetworkFailure,
      _ => false,
    };

/// 目标仓库本身（不是里面的文件）：只用来回答"这个仓库到底在不在、我看不看得见"。
///
/// 存在的理由是一个具体的坑（ADR-090）：Contents API 对"仓库/权限不对"和
/// "仓库在、只是这份文件还没推过"**都回 404**，只看那一个响应就会把
/// owner 拼错报成「连通成功，远程还没有备份」—— 把配置错误说成了正常状态。
class RemoteRepository {
  const RemoteRepository({
    required this.fullName,
    this.isPrivate = false,
    this.defaultBranch = '',
  });

  /// `owner/repo` 的规范写法（以 GitHub 回的那份为准，用户大小写写错了也照实显示）。
  final String fullName;

  /// 私有仓库 —— 我们的边界就建在"用户自建私有仓库"上（ADR-088）。
  final bool isPrivate;

  /// 默认分支：拉取/推送用的分支名写错时，这一条是对照物。
  final String defaultBranch;
}

/// 数一份数据文件里的活记录（**不含墓碑**）。
///
/// 与「导出·导入」那一页自己数活记录的口径一致：墓碑含进去会让
/// "远程 12 条 / 本地 9 条"这种数字对不上，比不给数字更糟。
int liveRecordCount(StoreFile store) {
  var total = 0;
  for (final name in DocName.values) {
    total += store.documentOf(name).items.where((item) => !item.deleted).length;
  }
  return total;
}

/// 把一份数据文件里的活记录按集合拆开（界面用来写"项目 3 · 灵感 5 · …"）。
Map<DocName, int> liveCountsOf(StoreFile store) => <DocName, int>{
      for (final name in DocName.values)
        name: store.documentOf(name).items.where((item) => !item.deleted).length,
    };

/// 判定"现在该做什么"。
///
/// 判定看两样东西：**两边的内容**（[diffStores] 比规范文本）与两个时间戳
/// （[StoreFile.savedAt]，也就是导出时的 `exportedAt`），外加上次同步的记账。
/// 内容那一步只回答"要不要动手"，**不做合并**：手机上把两份人生记录自动并起来，
/// 比让用户手动选一次危险得多，所以两边真不一样时仍旧让用户选。
SyncPlan analyzeSync({
  required StoreFile local,
  required int? localSavedAt,
  required RemoteBackup? remote,
  required SyncRecord? lastSync,
  String remoteCommitSha = '',
}) {
  final localCount = liveRecordCount(local);
  final remoteSavedAt = remote?.savedAt;
  final remoteCount = remote?.recordCount ?? 0;

  // 本地一条活记录都没有：先不管远程新旧，这条必须单独说清楚。
  if (localCount == 0) {
    return SyncPlan(
      action: SyncAction.localEmpty,
      message: '本机当前没有记录，远程备份中有 $remoteCount 条。\n'
          '推送会用本机的空数据覆盖远程备份，请确认是否继续。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  if (remote == null || !remote.readable) {
    return SyncPlan(
      action: SyncAction.push,
      message: '远程尚未有这份备份。\n'
          '推送会写入当前 $localCount 条记录，并新建一次提交。',
      localSavedAt: localSavedAt,
    );
  }

  // 判据与本地备份那一套同一句话：0 条不算可用备份。
  if (!remote.usable) {
    return SyncPlan(
      action: SyncAction.push,
      message: '远程备份读不出可用记录，0 条不算可用备份。\n'
          '推送会用当前 $localCount 条记录覆盖它，并从这次起留下可回退的历史。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  // 内容闸门（2026-10-01 反馈）：**两边内容一模一样就什么都不做**。
  //
  // 只比时间戳会把"刚拉回来的那一份"当成"本地改过"：拉取会把本地时间戳顶成
  // 拉取那一刻，于是下一次自动上传必然判定"本地比远程新"，把内容一字不差的
  // 文件再提交一次 —— 提交码不同，内容却是同一份（ADR-091 反对的正是这种提交）。
  // 这里换用与差异面板同一个判据（[diffStores] 比规范文本，比的是全部记录、
  // 因此不受时间戳影响）：**内容相同 ⇒ 判定成"同一份"**，不推、不拉、不记账。
  if (remote.payload != null) {
    final contentDiff = diffStores(base: remote.payload!.store, target: local);
    if (!contentDiff.hasChanges) {
      return SyncPlan(
        action: SyncAction.noChange,
        message: '这台手机上的内容和云端是同一份，'
            '只是时间戳对不上（两边最后都改于 ${formatStamp(localSavedAt)} / '
            '${formatStamp(remoteSavedAt)}）。\n'
            '共 $localCount 条记录，不需要推送也不需要拉取。',
        localSavedAt: localSavedAt,
        remoteSavedAt: remoteSavedAt,
      );
    }
  }

  if (localSavedAt == remoteSavedAt) {
    return SyncPlan(
      action: SyncAction.noChange,
      message: '两边最后都改于 ${formatStamp(localSavedAt)}，是同一份。\n'
          '共 $localCount 条记录，不需要推送也不需要拉取。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  // 需求④（ADR-093）：云端的提交码跟上次记账一致 ⇒ 这中间**没有第三方动过云端**
  // ⇒ 本地的改动直接覆盖上去，不摆差异面板、不追问。
  //
  // 位置：排在"两边时间戳一样（同一份）"**之后** —— 同一份内容不该为了覆盖再提交一次
  // （ADR-091 反对"内容一字不差的提交"，那会让仓库里堆满无意义的提交）；又排在
  // localEmpty 之后 —— 本机 0 条仍然停手（Q-1：读坏了也会显示成 0 条）。靠时间戳分流
  // 的那几条都在它后面：时间戳只能得出"本地新 → 推"或者"两边都动过 → 让用户选"，
  // 而后者正是这一段要免掉的追问。
  if (commitCodeMatches(
    remoteCommitSha: remoteCommitSha,
    lastSyncedCommitSha: lastSync?.commitSha,
  )) {
    return SyncPlan(
      action: SyncAction.push,
      trustedOverwrite: true,
      message: '云端仍是上次同步过的那一次提交 ${shortSha(remoteCommitSha)}，'
          '这期间没有第三方改动，本地可以直接覆盖云端。\n'
          '本地 $localCount 条，云端 $remoteCount 条。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  // 记账只在"上次同步过"时才有；没有记账时基线取 0，
  // 也就是两边都算"改过" —— 这正是最该让用户自己看的情形。
  final base = lastSync?.syncedAt ?? 0;
  final localChanged = localSavedAt == null || localSavedAt > base;
  final remoteChanged = remoteSavedAt == null || remoteSavedAt > base;

  if (localChanged && !remoteChanged) {
    return SyncPlan(
      action: SyncAction.push,
      message: '本地比远程新：本地 ${formatStamp(localSavedAt)}，共 $localCount 条；'
          '远程 ${formatStamp(remoteSavedAt)}，共 $remoteCount 条。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  if (!localChanged && remoteChanged) {
    return SyncPlan(
      action: SyncAction.pull,
      message: '远程比本地新：远程 ${formatStamp(remoteSavedAt)}，共 $remoteCount 条；'
          '本地 ${formatStamp(localSavedAt)}，共 $localCount 条。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  // 谁都没动过：两个时间戳都还不比上次同步新 —— 那就是同一份。
  // 这一条必须单独判：漏掉它会掉进下面的 bothChanged，
  // 于是"刚推完、什么都没改、再点一次推送"会被说成"两边都改过"。
  if (!localChanged && !remoteChanged) {
    return SyncPlan(
      action: SyncAction.noChange,
      message: '两边都仍是上次同步时的状态，本地 ${formatStamp(localSavedAt)}，'
          '远程 ${formatStamp(remoteSavedAt)}，期间双方都没有改动。\n'
          '共 $localCount 条记录，不需要推送也不需要拉取。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  // 两边都动过：给两个数字，让用户在知道各自条数的前提下自己选。
  return SyncPlan(
    action: SyncAction.bothChanged,
    message: '两边都改过：本地 ${formatStamp(localSavedAt)}，共 $localCount 条；'
        '远程 ${formatStamp(remoteSavedAt)}，共 $remoteCount 条。'
        '按时间看${_newerSide(localSavedAt, remoteSavedAt)}更新，但保留哪一边需要自行判断，'
        '这一步不会自动合并。',
    localSavedAt: localSavedAt,
    remoteSavedAt: remoteSavedAt,
  );
}

String _newerSide(int? local, int? remote) {
  if (local == null) return '远程';
  if (remote == null) return '本地';
  return local >= remote ? '本地' : '远程';
}

/// 把时间戳写成可读的本地时间；null 写成「未知时间」。
///
/// 刻意不引 `intl`：这里只需要给人看的一句话，而多一个依赖要跟着
/// Android 包体与许可清单一起走。
String formatStamp(int? millis) {
  if (millis == null) return '未知时间';
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 远程那份备份的提交说明里带上的摘要（推上去以后在 GitHub 上看得见）。
///
/// [appVersion] 形如 `1.9.0+38`，由调用方从 `AppInfo` 传进来 ——
/// 这一层不许 import `lib/platform`（分层硬线），但"这条提交是哪一版 App
/// 推的"只有 GitHub 页面上才看得出来，值得写进提交说明。
String commitMessageFor({
  required int nowMillis,
  required int recordCount,
  required String appVersion,
}) =>
    'backup: GuideLine $recordCount 条记录（${formatStamp(nowMillis)}）'
    '${appVersion.isEmpty ? '' : ' · $appVersion'}';
