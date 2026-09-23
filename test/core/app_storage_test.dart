import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/core/store/ui_prefs.dart';

/// 单机形态的存储层测试：**原子替换 + 备份轮转 + 损坏隔离/恢复**。
///
/// 没有云端，所以这几条就是数据安全的全部依靠。
void main() {
  late Directory dir;
  late AppStorage storage;

  const day = 1788652800000; // 2026-09-06

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_store_');
    storage = AppStorage(AppPaths(dir));
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  StoreFile storeWith(String title, {int savedAt = 0}) => StoreFile(
        documents: <DocName, Document>{
          for (final name in DocName.values) name: Document.empty(name),
          DocName.projects: Document(
            name: DocName.projects,
            items: <Project>[
              Project(
                id: 'p-$title',
                title: title,
                purpose: '',
                implementation: '',
                date: null,
                status: NodeStatus.pending,
                archived: false,
                parentProjectId: null,
                order: 1000,
                completedAt: null,
                createdAt: day,
                updatedAt: day,
                deleted: false,
              ),
            ],
          ),
        },
        savedAt: savedAt,
      );

  group('加载与保存', () {
    test('首次加载：空数据、无备份、无问题', () {
      final report = storage.load(nowMillis: day);
      expect(report.store.documentOf(DocName.projects).items, isEmpty);
      expect(report.quarantinedPaths, isEmpty);
      expect(report.recoveredFromBackup, isNull);
      expect(storage.listBackups(), isEmpty);
    });

    test('保存 → 重新加载：数据与时间戳都能读回', () {
      storage.save(storeWith('知识库'), nowMillis: day);

      final report = storage.load();
      expect(report.store.documentOf(DocName.projects).projectItems.single.title, '知识库');
      expect(report.store.savedAt, day);
    });

    test('保存后不留 .tmp 残留（原子替换）', () {
      storage.save(storeWith('项目'), nowMillis: day);
      expect(File('${storage.paths.storeFile.path}.tmp').existsSync(), isFalse);
    });

    test('落盘文本符合契约格式：2 空格缩进、LF、末尾单换行', () {
      storage.save(storeWith('项目'), nowMillis: day);
      final text = storage.paths.storeFile.readAsStringSync(encoding: utf8);
      expect(text.contains('\r'), isFalse);
      expect(text.endsWith('\n'), isTrue);
      expect(text.endsWith('\n\n'), isFalse);
      expect(text.contains('"schemaVersion": 2'), isTrue);
    });
  });

  group('备份轮转', () {
    test('第二次保存会把上一份轮转成 backup.1', () {
      storage.save(storeWith('第一版'), nowMillis: day);
      storage.save(storeWith('第二版'), nowMillis: day + 1000);

      final backup1 = storage.paths.rollingBackup(1);
      expect(backup1.existsSync(), isTrue);
      final parsed = StoreFile.parse(backup1.readAsStringSync(encoding: utf8), DecodeIssues());
      expect(parsed.documentOf(DocName.projects).projectItems.single.title, '第一版');
      expect(
        storage.paths.storeFile.readAsStringSync(encoding: utf8).contains('第二版'),
        isTrue,
      );
    });

    test('多次保存后按"越新越靠前"排列备份', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + 1);
      storage.save(storeWith('v3'), nowMillis: day + 2);

      String titleOf(int index) => StoreFile
          .parse(
            storage.paths.rollingBackup(index).readAsStringSync(encoding: utf8),
            DecodeIssues(),
          )
          .documentOf(DocName.projects)
          .projectItems
          .single
          .title;

      expect(titleOf(1), 'v2', reason: 'backup.1 是最近一次保存前的状态');
      expect(titleOf(2), 'v1');
    });

    test('每天第一份保存留下日快照，且同一天不会重复生成', () {
      storage.save(storeWith('第一天'), nowMillis: day);
      storage.save(storeWith('第一天再改'), nowMillis: day + 3600 * 1000);

      final dailies = storage.listBackups().where((b) => b.kind == BackupKind.daily).toList();
      expect(dailies.length, 1, reason: '同一天只留一份日快照');

      // 换一天 → 新增一份
      storage.save(storeWith('第二天'), nowMillis: day + 24 * 3600 * 1000);
      expect(
        storage.listBackups().where((b) => b.kind == BackupKind.daily).length,
        2,
      );
    });

    test('备份列表按"滚动备份在前、日快照在后"给出可读标签', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + 1);

      final entries = storage.listBackups();
      expect(entries.first.kind, BackupKind.rolling);
      expect(entries.first.label, contains('上一份'));
      expect(entries.any((e) => e.kind == BackupKind.daily && e.label.contains('日快照')), isTrue);
    });
  });

  group('损坏与恢复', () {
    test('主文件损坏 → 隔离现场 + 从备份自动恢复', () {
      storage.save(storeWith('完好版本'), nowMillis: day);
      storage.save(storeWith('最新版本'), nowMillis: day + 1);
      // 破坏主文件
      storage.paths.storeFile.writeAsStringSync('{"broken": ');

      final report = storage.load(nowMillis: day + 2);

      expect(report.quarantinedPaths, hasLength(1));
      expect(File(report.quarantinedPaths.single).existsSync(), isTrue, reason: '现场必须保留');
      expect(report.recoveredFromBackup, isNotNull);
      expect(
        report.store.documentOf(DocName.projects).projectItems.single.title,
        '完好版本',
        reason: 'backup.1 是最近一次保存前的状态',
      );
      expect(report.issues.warnings.any((w) => w.contains('备份')), isTrue);
    });

    test('主文件损坏且没有任何备份 → 隔离 + 空数据 + 明确告警（绝不静默）', () {
      storage.paths.ensureDirectories();
      storage.paths.storeFile.writeAsStringSync('not json');

      final report = storage.load(nowMillis: day);

      expect(report.quarantinedPaths, hasLength(1));
      expect(report.recoveredFromBackup, isNull);
      expect(report.store.documentOf(DocName.projects).items, isEmpty);
      expect(report.issues.errors, isNotEmpty);
    });

    test('从备份恢复：能把指定备份写回主文件，且当前数据先被轮转走', () {
      storage.save(storeWith('要保留的旧数据'), nowMillis: day);
      storage.save(storeWith('误操作后的数据'), nowMillis: day + 1);

      final backupPath = storage.paths.rollingBackup(1).path;
      final restored = storage.restoreFromBackup(backupPath, nowMillis: day + 2);

      expect(restored.documentOf(DocName.projects).projectItems.single.title, '要保留的旧数据');
      expect(storage.load().store.documentOf(DocName.projects).projectItems.single.title,
          '要保留的旧数据');
      // 恢复动作本身可回退：恢复前的数据进了 backup.1
      final rolled = StoreFile.parse(
        storage.paths.rollingBackup(1).readAsStringSync(encoding: utf8),
        DecodeIssues(),
      );
      expect(rolled.documentOf(DocName.projects).projectItems.single.title, '误操作后的数据');
    });
  });

  group('界面偏好', () {
    test('独立文件保存与读回，且不触碰主数据文件', () {
      storage.save(storeWith('项目'), nowMillis: day);
      final before = storage.paths.storeFile.readAsStringSync(encoding: utf8);

      storage.savePrefs(UiPrefs.empty.toggleCollapsed('p-1', true).copyWith(lastTabIndex: 2));

      final report = storage.load();
      expect(report.prefs.isCollapsed('p-1'), isTrue);
      expect(report.prefs.lastTabIndex, 2);
      expect(storage.paths.storeFile.readAsStringSync(encoding: utf8), before);
    });

    test('偏好文件损坏时静默重置（不影响数据）', () {
      storage.paths.ensureDirectories();
      storage.paths.prefsFile.writeAsStringSync('{ broken');
      final report = storage.load();
      expect(report.prefs.collapsedIds, isEmpty);
    });
  });
}
