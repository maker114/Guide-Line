import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/store/local_paths.dart';
import 'package:guideline/core/store/local_store.dart';
import 'package:guideline/features/portability.dart';
import 'package:guideline/features/workspace.dart';

/// 零第三方搬移：导出 / 导入（`.json.gz`）。
void main() {
  late Directory dirA;
  late Directory dirB;
  late Workspace wsA;
  late Workspace wsB;

  Workspace makeWorkspace(Directory dir) {
    final store = LocalStore(LocalPaths(dir));
    return Workspace.fromLoad(store, store.load());
  }

  setUp(() {
    dirA = Directory.systemTemp.createTempSync('guideline_exp_');
    dirB = Directory.systemTemp.createTempSync('guideline_imp_');
    wsA = makeWorkspace(dirA);
    wsB = makeWorkspace(dirB);
  });

  tearDown(() {
    if (dirA.existsSync()) dirA.deleteSync(recursive: true);
    if (dirB.existsSync()) dirB.deleteSync(recursive: true);
  });

  List<int> exportFrom(Workspace ws) =>
      Portability.exportBytes(ws, deviceId: 'dev-A', appVersion: '1.0.0', nowMillis: 1788652800000);

  ExportBundle decode(List<int> bytes) {
    final issues = DecodeIssues();
    final bundle = Portability.decodeBytes(bytes, issues);
    expect(issues.errors, isEmpty);
    expect(bundle, isNotNull);
    return bundle!;
  }

  test('导出→解码：4 份文档与版本号完整往返，且是 gzip 压缩', () {
    final project = wsA.createProject(title: '项目 A', purpose: '目的', implementation: '实现');
    wsA.captureInspiration('一条灵感');

    final bytes = exportFrom(wsA);

    expect(bytes.length, greaterThan(20));
    expect(bytes[0], 0x1f, reason: 'gzip 魔数');
    expect(bytes[1], 0x8b);

    final bundle = decode(bytes);
    expect(bundle.exportedAt, 1788652800000);
    expect(bundle.deviceId, 'dev-A');
    expect(bundle.documents.length, 4);
    expect(bundle.documents[DocName.projects]!.projectItems.first.id, project.id);
    expect(bundle.documents[DocName.inspirations]!.items.length, 1);
  });

  test('导出包含墓碑与墓碑骨架 —— 导入后已删数据不会复活', () {
    final project = wsA.createProject(title: '先删掉');
    wsA.deleteProject(project.id);
    wsA.purge(DocName.projects, wsA.purgeIdsFor(DocName.projects, project.id));

    final bundle = decode(exportFrom(wsA));
    final items = bundle.documents[DocName.projects]!.items;

    expect(items.length, 1);
    expect(items.first, isA<Tombstone>());
    expect(items.first.toJson().keys.toList(), <String>['id', 'deleted', 'purged_at']);
  });

  test('导入到空设备：全部按"导入包更新"采用', () {
    final project = wsA.createProject(title: '项目 A');
    wsA.captureInspiration('灵感 A');
    wsA.persist();

    final report = Portability.apply(wsB, decode(exportFrom(wsA)), nowMillis: 1788652900000);

    expect(report.needsUserDecision, isFalse);
    expect(report.applied.length, 2, reason: 'projects / inspirations 有内容；events / tasks 都是空 → identical');
    expect(wsB.findProject(project.id), isNotNull);
    expect(wsB.inspirationInbox.length, 1);
  });

  test('内容相同时判为 identical，不写入也不留脏', () {
    wsA.createProject(title: '同一个项目');
    wsA.persist();
    final bytes = exportFrom(wsA);

    // B 端导入一次 → 完全一致；再导一次做对比
    Portability.apply(wsB, decode(bytes));
    final second = Portability.preview(wsB, decode(bytes));

    expect(second.every((d) => d.action == ImportAction.identical), isTrue);
    expect(wsB.dirtyDocs, isEmpty);
  });

  test('本地有未提交改动且导入包不同 → 冲突；未选择时保持本地并落草稿', () {
    wsA.createProject(title: 'A 的项目');
    wsA.persist();

    // B 端先同步到 A 的状态，然后 B 本地又改了
    Portability.apply(wsB, decode(exportFrom(wsA)));
    final localProject = wsB.liveProjects.first;
    wsB.updateProject(localProject.id, title: 'B 本地改过的标题');

    // A 端也改了同一个文档并导出
    wsA.updateProject(wsA.liveProjects.first.id, title: 'A 端改过的标题');
    wsA.persist();
    final bundle = decode(exportFrom(wsA));

    final preview = Portability.preview(wsB, bundle);
    final decision = preview.firstWhere((d) => d.name == DocName.projects);
    expect(decision.action, ImportAction.conflict);

    final report = Portability.apply(wsB, bundle);

    expect(report.needsUserDecision, isTrue);
    expect(wsB.findProject(localProject.id)!.title, 'B 本地改过的标题',
        reason: '未选择时保持本地，不静默覆盖');
    expect(report.draftPaths.length, 1);
    expect(File(report.draftPaths.first).existsSync(), isTrue);
    expect(File(report.draftPaths.first).path, contains('imported_'),
        reason: '导入冲突草稿要能和云同步冲突草稿区分开');
  });

  test('冲突时选择"以导入包为准" → 本地未提交内容落草稿后再替换', () {
    wsA.createProject(title: 'A 的项目');
    wsA.persist();
    Portability.apply(wsB, decode(exportFrom(wsA)));
    final localProject = wsB.liveProjects.first;
    wsB.updateProject(localProject.id, title: 'B 本地改过的标题');

    wsA.updateProject(wsA.liveProjects.first.id, title: 'A 端改过的标题');
    wsA.persist();
    final bundle = decode(exportFrom(wsA));

    final report = Portability.apply(
      wsB,
      bundle,
      choices: <DocName, ImportConflictChoice>{
        DocName.projects: ImportConflictChoice.takeIncoming,
      },
    );

    expect(wsB.findProject(localProject.id)!.title, 'A 端改过的标题');
    expect(report.draftPaths.length, 1);
    expect(File(report.draftPaths.first).path, contains('conflict_'),
        reason: '被覆盖的本地内容必须有草稿留底');
  });

  test('导入包版本更低时保留本地（本地已同步到更高版本）', () {
    wsA.createProject(title: '旧');
    wsA.persist();
    final oldBytes = exportFrom(wsA);

    wsB.createProject(title: '新');
    wsB.persist();
    // 模拟 B 已经与云端同步过：本地版本领先
    wsB.markSynced(DocName.projects, 5);

    final preview = Portability.preview(wsB, decode(oldBytes));
    final decision = preview.firstWhere((d) => d.name == DocName.projects);

    expect(decision.action, ImportAction.keepLocal);
    expect(wsB.liveProjects.first.title, '新');
  });

  test('版本相同、本地干净但内容不同 → 采用导入包（离线搬移的主路径）', () {
    wsA.createProject(title: 'A 建的项目');
    wsA.persist();

    // B 上有一条自己的、从未同步过的数据（版本号同样是 0）
    wsB.createProject(title: 'B 建的项目');
    wsB.persist();
    wsB.clearDirty(wsB.dirtyDocs); // 模拟"已提交过"（无未提交改动）

    final preview = Portability.preview(wsB, decode(exportFrom(wsA)));
    final decision = preview.firstWhere((d) => d.name == DocName.projects);
    expect(decision.action, ImportAction.takeIncoming);
  });

  test('损坏的导出包给出可读错误而不是抛异常', () {
    final issues = DecodeIssues();
    expect(Portability.decodeBytes(<int>[1, 2, 3, 4], issues), isNull);
    expect(issues.errors, isNotEmpty);

    final wrongFormat = DecodeIssues();
    final bytes = Portability.exportBytes(wsA);
    final text = String.fromCharCodes(bytes);
    expect(text.isNotEmpty, isTrue);
    expect(
      Portability.decodeBytes(gzipEncode('{"format":"something-else"}'), wrongFormat),
      isNull,
    );
    expect(wrongFormat.errors.first, contains('不是 GuideLine 导出包'));
  });

  test('文件名带时间戳，便于人工区分', () {
    final name = Portability.suggestedFileName(1788652800000);
    expect(name.startsWith('guideline-export-'), isTrue);
    expect(name.endsWith('.json.gz'), isTrue);
  });
}

List<int> gzipEncode(String text) => gzip.encode(text.codeUnits);
