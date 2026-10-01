import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/core/store/github_sync.dart';

/// GitHub 备份同步的**判定内核**（纯 Dart，不联网）。
///
/// 这一层只有一件事值得钉死：**"现在该做什么"不许猜**。
/// 尤其是"两边都改过"—— 那一步一旦自动合并，手机上两份人生记录就并成了
/// 一份谁也说不清的东西，所以它必须退回 [SyncAction.bothChanged] 让用户自己选。
///
/// 另一条同样要紧：**0 条不算可用备份**。这条判据在本地备份列表里已经有了
/// （`AppStorage._recordCountOf`），远程这一侧是同一句话 ——
/// 空文件被当成"备份"，拿它覆盖本地等于静默清空。
void main() {
  const int t1 = 1788652800000; // 2026-09-23 08:00 UTC
  const int t2 = t1 + 3600000;

  Project project(String id) => Project(
        id: id,
        title: '指南线',
        purpose: '目的',
        implementation: '实现',
        date: '2026-09-23',
        status: NodeStatus.pending,
        archived: false,
        parentProjectId: null,
        order: 1000,
        completedAt: null,
        createdAt: t1,
        updatedAt: t1,
        deleted: false,
      );

  Inspiration inspiration(String id, {bool deleted = false}) => Inspiration(
        id: id,
        text: '速记优先',
        projectId: null,
        status: InspirationStatus.pending,
        mergedInto: null,
        mergedAt: null,
        createdAt: t1,
        updatedAt: t1,
        deleted: deleted,
      );

  /// 一份"有东西"的数据：一个项目 + N 条灵感（可含墓碑）。
  StoreFile storeWith({
    required int savedAt,
    int projects = 1,
    int inspirations = 1,
    int tombstones = 0,
  }) =>
      StoreFile(
        savedAt: savedAt,
        documents: <DocName, Document>{
          for (final name in DocName.values) name: Document.empty(name),
          DocName.projects: Document(
            name: DocName.projects,
            items: <Entity>[for (var i = 0; i < projects; i++) project('p$i')],
          ),
          DocName.inspirations: Document(
            name: DocName.inspirations,
            items: <Entity>[
              for (var i = 0; i < inspirations; i++) inspiration('i$i'),
              for (var i = 0; i < tombstones; i++)
                inspiration('dead$i', deleted: true),
            ],
          ),
        },
      );

  /// 把一份数据做成"远程那一份"（走与真实推送完全相同的编码）。
  RemoteBackup remoteOf(StoreFile store, {int? exportedAt, String sha = 'sha-1'}) =>
      RemoteBackup.fromBytes(
        path: 'backups/guideline-latest.json.gz',
        sha: sha,
        bytes: ExportCodec.encode(store, exportedAt: exportedAt ?? store.savedAt),
      );

  group('活记录条数（墓碑不算）', () {
    test('只数未删除的记录', () {
      final store = storeWith(savedAt: t1, projects: 2, inspirations: 3, tombstones: 4);
      expect(liveRecordCount(store), 5);
    });

    test('一份空数据是 0 条', () {
      expect(liveRecordCount(StoreFile.empty()), 0);
      expect(liveRecordCount(storeWith(savedAt: t1, projects: 0, inspirations: 0)), 0);
    });

    test('按集合拆开的计数与总数对得上', () {
      final store = storeWith(savedAt: t1, projects: 2, inspirations: 3, tombstones: 1);
      final counts = liveCountsOf(store);
      expect(counts[DocName.projects], 2);
      expect(counts[DocName.inspirations], 3);
      expect(counts.values.fold<int>(0, (sum, value) => sum + value), 5);
    });
  });

  group('远程那一份解出来是什么', () {
    test('自家导出的能原样读回，条数与时间都对', () {
      final remote = remoteOf(storeWith(savedAt: t1, projects: 1, inspirations: 2));
      expect(remote.readable, isTrue);
      expect(remote.usable, isTrue);
      expect(remote.recordCount, 3);
      expect(remote.savedAt, t1);
    });

    test('垃圾字节读不出 → readable / usable 都为假，条数当 0', () {
      final remote = RemoteBackup.fromBytes(
        path: 'backups/guideline-latest.json.gz',
        sha: 'sha-x',
        bytes: <int>[1, 2, 3, 4, 5],
      );
      expect(remote.readable, isFalse);
      expect(remote.usable, isFalse);
      expect(remote.recordCount, 0);
      expect(remote.savedAt, isNull);
    });

    test('能读出来但 0 条活记录 → 不算可用备份', () {
      final remote = remoteOf(StoreFile.empty());
      expect(remote.readable, isTrue);
      expect(remote.usable, isFalse);
      expect(remote.recordCount, 0);
    });

    test('全是墓碑 → 算 0 条，同样不算可用备份', () {
      final remote = remoteOf(
        storeWith(savedAt: t1, projects: 0, inspirations: 0, tombstones: 3),
      );
      expect(remote.readable, isTrue);
      expect(remote.recordCount, 0);
      expect(remote.usable, isFalse);
    });
  });

  group('冲突判定', () {
    test('远程还没有这份备份 → 推', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t1),
        localSavedAt: t1,
        remote: null,
        lastSync: null,
      );
      expect(plan.action, SyncAction.push);
      expect(plan.message, contains('远程尚未有这份备份'));
      expect(plan.needsExtraConfirm, isFalse);
    });

    test('远程读不出 / 0 条 → 推（不许拿它当基线）', () {
      for (final remote in <RemoteBackup?>[
        RemoteBackup.fromBytes(path: 'p', sha: 's', bytes: <int>[9, 9, 9]),
        remoteOf(StoreFile.empty()),
      ]) {
        final plan = analyzeSync(
          local: storeWith(savedAt: t1),
          localSavedAt: t1,
          remote: remote,
          lastSync: SyncRecord(syncedAt: t1, remoteSha: 's', recordCount: 9),
        );
        expect(plan.action, SyncAction.push);
      }
    });

    test('两边最后改于同一刻 → 什么都不做', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t1),
        localSavedAt: t1,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: null,
      );
      expect(plan.action, SyncAction.noChange);
      expect(plan.needsExtraConfirm, isFalse);
    });

    test('只有本地改过（本地比记账新、远程比记账旧）→ 推', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2, inspirations: 2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(syncedAt: t1, remoteSha: 'sha-1', recordCount: 2),
      );
      expect(plan.action, SyncAction.push);
      expect(plan.message, contains('本地比远程新'));
    });

    test('只有远程改过 → 拉', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t1),
        localSavedAt: t1,
        remote: remoteOf(storeWith(savedAt: t2, inspirations: 2)),
        lastSync: SyncRecord(syncedAt: t1, remoteSha: 'sha-1', recordCount: 2),
      );
      expect(plan.action, SyncAction.pull);
      expect(plan.message, contains('远程比本地新'));
    });

    test('两边都改过 → 退回 bothChanged，且明确写着不会自动合并', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2, inspirations: 2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t2 + 1)),
        lastSync: SyncRecord(syncedAt: t1, remoteSha: 'sha-1', recordCount: 2),
      );
      expect(plan.action, SyncAction.bothChanged);
      expect(plan.message, contains('两边都改过'));
      expect(plan.message, contains('不会自动合并'));
    });

    test('没有记账时基线取 0，两边都算改过 → bothChanged', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t1, inspirations: 2),
        localSavedAt: t1,
        remote: remoteOf(storeWith(savedAt: t2)),
        lastSync: null,
      );
      expect(plan.action, SyncAction.bothChanged);
    });

    test('谁都没动过（上次同步之后两边都没改）→ noChange，不许说成两边都改过', () {
      // 活着的内容一模一样，只有**墓碑**不同：这样内容闸门放行，
      // 一路走到按时间戳判定的那一步 —— 这条要验的正是那一步。
      final plan = analyzeSync(
        local: storeWith(savedAt: t1),
        localSavedAt: t1,
        remote: remoteOf(storeWith(savedAt: t1 - 60000, tombstones: 1)),
        lastSync: SyncRecord(syncedAt: t2, remoteSha: 'sha-1', recordCount: 2),
      );
      expect(plan.action, SyncAction.noChange);
      expect(plan.message, contains('两边都仍是上次同步时的状态'));
    });

    test('本地一条活记录都没有 → localEmpty，且要求额外确认一次', () {
      final plan = analyzeSync(
        local: StoreFile.empty(),
        localSavedAt: null,
        remote: remoteOf(storeWith(savedAt: t1, projects: 3)),
        lastSync: null,
      );
      expect(plan.action, SyncAction.localEmpty);
      expect(plan.needsExtraConfirm, isTrue);
      expect(plan.message, contains('本机当前没有记录'));
    });

    test('本地只有墓碑也算空 → localEmpty（与条数判据同一把尺子）', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t1, projects: 0, inspirations: 0, tombstones: 2),
        localSavedAt: t1,
        remote: remoteOf(storeWith(savedAt: t1, projects: 3)),
        lastSync: null,
      );
      expect(plan.action, SyncAction.localEmpty);
    });

    test('判定把两边的时间与条数都摆出来，用户不必猜', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2, projects: 1, inspirations: 4),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1, projects: 2, inspirations: 1)),
        lastSync: SyncRecord(syncedAt: t1, remoteSha: 'sha-1', recordCount: 3),
      );
      expect(plan.action, SyncAction.push);
      expect(plan.localSavedAt, t2);
      expect(plan.remoteSavedAt, t1);
      expect(plan.message, contains('5 条'));
      expect(plan.message, contains('3 条'));
    });
  });

  group('记账（SyncRecord）', () {
    test('写出去能原样读回来', () {
      const record = SyncRecord(syncedAt: t1, remoteSha: 'abc123', recordCount: 7);
      final back = SyncRecord.parse(record.toCanonicalText());
      expect(back, isNotNull);
      expect(back!.syncedAt, t1);
      expect(back.remoteSha, 'abc123');
      expect(back.recordCount, 7);
    });

    test('坏掉的记账当没有：不抛错、只返回 null', () {
      expect(SyncRecord.parse(null), isNull);
      expect(SyncRecord.parse(''), isNull);
      expect(SyncRecord.parse('不是 json'), isNull);
      expect(SyncRecord.parse('[1,2,3]'), isNull);
      expect(SyncRecord.parse('{"syncedAt":1}'), isNull);
      // sha 空 / 时刻非正 / 条数为负：都算坏记账
      expect(
        SyncRecord.parse('{"syncedAt":1,"remoteSha":"","recordCount":1}'),
        isNull,
      );
      expect(
        SyncRecord.parse('{"syncedAt":0,"remoteSha":"a","recordCount":1}'),
        isNull,
      );
      expect(
        SyncRecord.parse('{"syncedAt":1,"remoteSha":"a","recordCount":-1}'),
        isNull,
      );
    });

    test('copyWith 只改点名的那几项', () {
      const record = SyncRecord(syncedAt: t1, remoteSha: 'a', recordCount: 1);
      final next = record.copyWith(recordCount: 5);
      expect(next.syncedAt, t1);
      expect(next.remoteSha, 'a');
      expect(next.recordCount, 5);
    });

    test('提交码原样读回来；未知（空串）就不写出去', () {
      const code = 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef';
      const record = SyncRecord(
        syncedAt: t1,
        remoteSha: 'abc123',
        recordCount: 7,
        commitSha: code,
      );
      final text = record.toCanonicalText();
      expect(text, contains('commitSha'));
      expect(SyncRecord.parse(text)!.commitSha, code);

      const unknown = SyncRecord(syncedAt: t1, remoteSha: 'abc123', recordCount: 7);
      expect(
        unknown.toCanonicalText(),
        isNot(contains('commitSha')),
        reason: '未知就不写出去，与"空值不写出"的契约口径一致',
      );
    });

    test('1.8.5 及以前的老记账没有提交码：读出来是未知，不是坏记账', () {
      final old = SyncRecord.parse(
        '{"syncedAt":$t1,"remoteSha":"abc123","recordCount":7}',
      );
      expect(old, isNotNull, reason: '老记账必须照旧能读，不能被升级弄坏');
      expect(
        old!.commitSha,
        '',
        reason: '缺这一项 =未知，不许判成"双端版本不一致"',
      );
    });
  });

  group('提交码与内容码', () {
    test('短码取前 7 位；空串写「未知」而不是空着', () {
      expect(shortSha('abc1234def5678'), 'abc1234');
      expect(shortSha('abc'), 'abc');
      expect(shortSha(''), '未知');
    });

    test('RemoteCommit：读不到提交码时 known 是 false', () {
      expect(const RemoteCommit(sha: '').known, isFalse);
      const found = RemoteCommit(
        sha: 'abc1234',
        message: 'backup: GuideLine 3 条记录',
        committedAt: t1,
      );
      expect(found.known, isTrue);
      expect(found.message, 'backup: GuideLine 3 条记录');
      expect(found.committedAt, t1);
    });

    test('写回来的提交码跟着 RemoteBackup 一起带出来（内容码另有其人）', () {
      final backup = RemoteBackup.fromBytes(
        path: 'backups/guideline-latest.json.gz',
        sha: 'blob-sha',
        bytes: ExportCodec.encode(StoreFile.empty(), exportedAt: t1),
        commitSha: 'commit-sha',
      );
      expect(backup.sha, 'blob-sha', reason: '内容码还是内容码');
      expect(backup.commitSha, 'commit-sha', reason: '提交码要单独带一份');
    });
  });

  group('给人看的两句话', () {
    test('时间戳写成可读本地时间，null 写「未知时间」', () {
      expect(formatStamp(null), '未知时间');
      final text = formatStamp(t1);
      expect(text, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
    });

    test('提交说明带上条数，在 GitHub 上一眼看得懂', () {
      final message = commitMessageFor(
        nowMillis: t1,
        recordCount: 12,
        appVersion: '1.9.0+38',
      );
      expect(message, contains('12 条记录'));
      expect(message, startsWith('backup: GuideLine'));
      expect(
        message,
        contains('1.9.0+38'),
        reason: '带上版本号，GitHub 的提交列表里才看得出是哪一版推的',
      );
    });

    test('没有版本号就不缀那一段，不留一个孤零零的分隔号', () {
      final message = commitMessageFor(nowMillis: t1, recordCount: 3, appVersion: '');
      expect(message, isNot(contains('·')));
      expect(message, contains('3 条记录'));
    });
  });

  group('需求④：云端提交码对得上就直接覆盖（ADR-093）', () {
    test('对得上：推，并挂上 trustedOverwrite（自动与手动都不再追问）', () {
      final plan = analyzeSync(
        // 内容必须**真的**不一样：提交码对得上只是"没人动过云端"，
        // 内容一字不差时连提交都不该发（内容闸门，见下面那条）。
        local: storeWith(savedAt: t2, inspirations: 2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(
          syncedAt: t1,
          remoteSha: 'sha-1',
          recordCount: 2,
          commitSha: 'commit-same',
        ),
        remoteCommitSha: 'commit-same',
      );

      expect(plan.action, SyncAction.push);
      expect(
        plan.trustedOverwrite,
        isTrue,
        reason: '这中间没人动过云端，本机直接覆盖上去（需求④）',
      );
      expect(plan.message, contains('云端仍是上次同步过的那一次提交'));
      expect(plan.message, contains('没有第三方改动'));
    });

    test('内容闸门：提交码对不上但内容一字不差时也不推（需求③）', () {
      // 正是用户报的那一种：刚从 GitHub 拉回来，本地时间戳被顶成"刚改过"，
      // 提交码和记账对不上 —— 只看提交码就会把同一份内容再提交一次。
      final plan = analyzeSync(
        local: storeWith(savedAt: t2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(
          syncedAt: t1,
          remoteSha: 'sha-1',
          recordCount: 2,
          commitSha: 'commit-old',
        ),
        remoteCommitSha: 'commit-new',
      );

      expect(plan.action, SyncAction.noChange);
      expect(plan.trustedOverwrite, isFalse);
      expect(plan.message, contains('内容'));
      expect(plan.message, contains('不需要推送也不需要拉取'));
    });

    test('内容闸门：真改过一条就不再是 noChange', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2, inspirations: 2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(
          syncedAt: t1,
          remoteSha: 'sha-1',
          recordCount: 2,
          commitSha: 'commit-old',
        ),
        remoteCommitSha: 'commit-new',
      );

      expect(plan.action, SyncAction.push, reason: '本地确实多了一条灵感');
      expect(plan.trustedOverwrite, isFalse, reason: '提交码对不上，得按老规矩摆面板');
    });

    test('对不上：还是普通推，要不要摆面板由上层按老规矩来', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2, inspirations: 2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(
          syncedAt: t1,
          remoteSha: 'sha-1',
          recordCount: 2,
          commitSha: 'commit-same',
        ),
        remoteCommitSha: 'commit-other',
      );

      expect(plan.action, SyncAction.push, reason: '本地确实比远程新，但先让人看一眼');
      expect(plan.trustedOverwrite, isFalse);
      expect(plan.message, contains('本地比远程新'));
    });

    test('两边时间戳一样时不推：同一份内容不为"覆盖"再提交一次（ADR-091）', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t1),
        localSavedAt: t1,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(
          // 记账更早，让"提交码对得上"那条路真的有机会被走到。
          syncedAt: t1 - 999999,
          remoteSha: 'sha-1',
          recordCount: 2,
          commitSha: 'commit-same',
        ),
        remoteCommitSha: 'commit-same',
      );

      expect(plan.action, SyncAction.noChange);
      expect(
        plan.trustedOverwrite,
        isFalse,
        reason: '一字不差的提交只是给仓库添噪音',
      );
    });

    test('老记账没有提交码：不算对得上，回到老规矩', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2, inspirations: 2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(syncedAt: t1, remoteSha: 'sha-1', recordCount: 2),
        remoteCommitSha: 'commit-same',
      );

      expect(plan.trustedOverwrite, isFalse, reason: '1.8.5 及以前没记提交码，只能当未知');
    });

    test('云端提交码读不到（空串）：同样不算对得上', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2, inspirations: 2),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(
          syncedAt: t1,
          remoteSha: 'sha-1',
          recordCount: 2,
          commitSha: 'commit-same',
        ),
        remoteCommitSha: '',
      );

      expect(plan.trustedOverwrite, isFalse);
    });

    test('本机 0 条仍然压在最前面：提交码对得上也不拿空的覆盖云端', () {
      final plan = analyzeSync(
        local: StoreFile.empty(),
        localSavedAt: t2,
        remote: remoteOf(storeWith(savedAt: t1)),
        lastSync: SyncRecord(
          syncedAt: t1,
          remoteSha: 'sha-1',
          recordCount: 2,
          commitSha: 'commit-same',
        ),
        remoteCommitSha: 'commit-same',
      );

      expect(plan.action, SyncAction.localEmpty, reason: '读坏了也会显示成 0 条（Q-1）');
      expect(plan.trustedOverwrite, isFalse);
    });
  });

  group('提交码对得上吗', () {
    test('两侧都非空、一字相等才算对得上', () {
      expect(
        commitCodeMatches(remoteCommitSha: 'abc', lastSyncedCommitSha: 'abc'),
        isTrue,
      );
    });

    test('不一样、缺一边、传 null，都不算', () {
      expect(
        commitCodeMatches(remoteCommitSha: 'abc', lastSyncedCommitSha: 'abd'),
        isFalse,
      );
      expect(
        commitCodeMatches(remoteCommitSha: 'abc', lastSyncedCommitSha: ''),
        isFalse,
      );
      expect(commitCodeMatches(remoteCommitSha: '', lastSyncedCommitSha: 'abc'), isFalse);
      expect(
        commitCodeMatches(remoteCommitSha: null, lastSyncedCommitSha: null),
        isFalse,
        reason: '"两边都不知道"不能说成"没被改过"',
      );
      expect(commitCodeMatches(remoteCommitSha: 'abc', lastSyncedCommitSha: null), isFalse);
    });
  });

  group('连不上 GitHub 的原话认不认得出（需求⑤）', () {
    test('平台层那几句网络原话都算连不上', () {
      expect(looksOffline('连不上 api.github.com（检查网络或代理设置）'), isTrue);
      expect(looksOffline('网络请求失败，稍后再试'), isTrue);
      expect(looksOffline('请求超时（10 秒），稍后再试'), isTrue);
    });

    test('别的错（Token、权限）不算连不上：那是真失败，右上角要画红的', () {
      expect(looksOffline('还没填 Token'), isFalse);
      expect(looksOffline('GitHub 说没有权限（401）'), isFalse);
      expect(looksOffline(''), isFalse);
    });
  });
}
