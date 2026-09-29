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
      expect(plan.message, contains('远程还没有这份备份'));
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
        local: storeWith(savedAt: t2),
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
        remote: remoteOf(storeWith(savedAt: t2)),
        lastSync: SyncRecord(syncedAt: t1, remoteSha: 'sha-1', recordCount: 2),
      );
      expect(plan.action, SyncAction.pull);
      expect(plan.message, contains('远程比本地新'));
    });

    test('两边都改过 → 退回 bothChanged，且明确写着不会自动合并', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t2),
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
        local: storeWith(savedAt: t1),
        localSavedAt: t1,
        remote: remoteOf(storeWith(savedAt: t2)),
        lastSync: null,
      );
      expect(plan.action, SyncAction.bothChanged);
    });

    test('谁都没动过（上次同步之后两边都没改）→ noChange，不许说成两边都改过', () {
      final plan = analyzeSync(
        local: storeWith(savedAt: t1),
        localSavedAt: t1,
        // 两个时间戳故意错开：相等的那条走的是上面那个更早的分支
        remote: remoteOf(storeWith(savedAt: t1 - 60000)),
        lastSync: SyncRecord(syncedAt: t2, remoteSha: 'sha-1', recordCount: 2),
      );
      expect(plan.action, SyncAction.noChange);
      expect(plan.message, contains('谁都没改过'));
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
      expect(plan.message, contains('擦成空'));
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
  });

  group('给人看的两句话', () {
    test('时间戳写成可读本地时间，null 写「未知时间」', () {
      expect(formatStamp(null), '未知时间');
      final text = formatStamp(t1);
      expect(text, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
    });

    test('提交说明带上条数，在 GitHub 上一眼看得懂', () {
      final message = commitMessageFor(nowMillis: t1, recordCount: 12);
      expect(message, contains('12 条记录'));
      expect(message, startsWith('backup: GuideLine'));
    });
  });
}
