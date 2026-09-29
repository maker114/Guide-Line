import '../json/canonical.dart';
import '../json/store_file.dart';
import '../models/entity.dart';
import '../models/enums.dart';
import 'export_codec.dart';

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
  });

  final SyncAction action;

  /// 可以直接显示给用户的中文说明（含两边的时间与条数）。
  final String message;

  /// 本地那一份的最后修改时间（没有数据时为 null）。
  final int? localSavedAt;

  /// 远程那一份的最后修改时间（没有这份文件时为 null）。
  final int? remoteSavedAt;

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
      return SyncRecord(
        syncedAt: syncedAt,
        remoteSha: sha,
        recordCount: count,
        commitSha: commit is String ? commit : '',
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
      });

  SyncRecord copyWith({
    int? syncedAt,
    String? remoteSha,
    int? recordCount,
    String? commitSha,
  }) =>
      SyncRecord(
        syncedAt: syncedAt ?? this.syncedAt,
        remoteSha: remoteSha ?? this.remoteSha,
        recordCount: recordCount ?? this.recordCount,
        commitSha: commitSha ?? this.commitSha,
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
/// 判定只看两个时间戳（[StoreFile.savedAt]，也就是导出时的 `exportedAt`）
/// 与上次同步的记账 —— 不解析字段、不做合并。**这不是省事，是口径**：
/// 手机上把两份人生记录自动并起来，比让用户手动选一次危险得多。
SyncPlan analyzeSync({
  required StoreFile local,
  required int? localSavedAt,
  required RemoteBackup? remote,
  required SyncRecord? lastSync,
}) {
  final localCount = liveRecordCount(local);
  final remoteSavedAt = remote?.savedAt;
  final remoteCount = remote?.recordCount ?? 0;

  // 本地一条活记录都没有：先不管远程新旧，这条必须单独说清楚。
  if (localCount == 0) {
    return SyncPlan(
      action: SyncAction.localEmpty,
      message: '这台手机上现在一条记录都没有（远程那一份有 $remoteCount 条）。\n'
          '推上去等于把远程那份擦成空的 —— 确定要这么做吗？',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  if (remote == null || !remote.readable) {
    return SyncPlan(
      action: SyncAction.push,
      message: '远程还没有这份备份。\n'
          '推送会把当前 $localCount 条记录写上去，并新建这次提交。',
      localSavedAt: localSavedAt,
    );
  }

  // 判据与本地备份那一套同一句话：0 条不算可用备份。
  if (!remote.usable) {
    return SyncPlan(
      action: SyncAction.push,
      message: '远程那份读不出可用记录（0 条不算可用备份）。\n'
          '推送会用当前 $localCount 条记录覆盖它，并从这次起留下可回退的历史。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
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

  // 记账只在"上次同步过"时才有；没有记账时基线取 0，
  // 也就是两边都算"改过" —— 这正是最该让用户自己看的情形。
  final base = lastSync?.syncedAt ?? 0;
  final localChanged = localSavedAt == null || localSavedAt > base;
  final remoteChanged = remoteSavedAt == null || remoteSavedAt > base;

  if (localChanged && !remoteChanged) {
    return SyncPlan(
      action: SyncAction.push,
      message: '本地比远程新：本地 ${formatStamp(localSavedAt)}（$localCount 条），'
          '远程 ${formatStamp(remoteSavedAt)}（$remoteCount 条）。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  if (!localChanged && remoteChanged) {
    return SyncPlan(
      action: SyncAction.pull,
      message: '远程比本地新：远程 ${formatStamp(remoteSavedAt)}（$remoteCount 条），'
          '本地 ${formatStamp(localSavedAt)}（$localCount 条）。',
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
      message: '两边都还是上次同步时的那一份（本地 ${formatStamp(localSavedAt)}，'
          '远程 ${formatStamp(remoteSavedAt)}），中间谁都没改过。\n'
          '共 $localCount 条记录，不需要推送也不需要拉取。',
      localSavedAt: localSavedAt,
      remoteSavedAt: remoteSavedAt,
    );
  }

  // 两边都动过：给两个数字，让用户在知道各自条数的前提下自己选。
  return SyncPlan(
    action: SyncAction.bothChanged,
    message: '两边都改过：本地 ${formatStamp(localSavedAt)}（$localCount 条），'
        '远程 ${formatStamp(remoteSavedAt)}（$remoteCount 条）。\n'
        '按时间看${_newerSide(localSavedAt, remoteSavedAt)}更新，但条数差多少得你自己定 —— '
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
