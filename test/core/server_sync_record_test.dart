import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/core/store/github_sync.dart';

/// 服务器同步的记账与 GitHub 的**分文件**存：一条的同步不能让另一条误判。
void main() {
  late Directory dir;
  late AppStorage storage;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_server_sync_');
    storage = AppStorage(AppPaths(dir));
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('server_sync.json 能写能读，且不出现在 GitHub 记账里', () {
    expect(storage.readServerSyncRecord(), isNull);
    expect(storage.readSyncRecord(), isNull);

    storage.writeServerSyncRecord(
      SyncRecord(
        syncedAt: 1700000000000,
        remoteSha: 'a' * 64,
        recordCount: 7,
        commitSha: '3',
        localSha: 'b' * 64,
        localCommitSha: '3',
      ),
    );

    final record = storage.readServerSyncRecord()!;
    expect(record.syncedAt, 1700000000000);
    expect(record.recordCount, 7);
    expect(record.commitSha, '3');
    expect(record.localCommitSha, '3');

    // GitHub 那一份必须还是"没同步过"：两条线各有各的记账。
    expect(storage.readSyncRecord(), isNull);
    expect(
      File('${dir.path}${Platform.pathSeparator}server_sync.json').existsSync(),
      isTrue,
    );
  });

  test('清掉服务器记账不影响 GitHub 记账', () {
    storage.writeSyncRecord(
      SyncRecord(
        syncedAt: 1,
        remoteSha: 'x',
        recordCount: 1,
        commitSha: 'c0ffee',
      ),
    );
    storage.writeServerSyncRecord(
      SyncRecord(
        syncedAt: 2,
        remoteSha: 'y',
        recordCount: 2,
        commitSha: '2',
      ),
    );

    storage.clearServerSyncRecord();
    expect(storage.readServerSyncRecord(), isNull);
    expect(storage.readSyncRecord()?.commitSha, 'c0ffee');
  });
}
