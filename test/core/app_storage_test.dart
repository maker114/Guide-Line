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

      // 恢复出来的数据必须**当场写回主文件**。
      // 否则这次恢复只活在内存里：用户没做任何改动就退出，下次启动主文件依旧不存在，
      // 而 load 对「没有主文件」的处理是「空数据 + 不告警」——
      // 界面上就是一个崭新的空库，看起来等同于数据全丢（真机上真的这么翻过车）。
      expect(storage.paths.storeFile.existsSync(), isTrue, reason: '恢复后主文件必须重建');

      final again = storage.load(nowMillis: day + 3);
      expect(again.recoveredFromBackup, isNull, reason: '主文件已修好，不该再走一次恢复');
      expect(again.quarantinedPaths, isEmpty);
      expect(
        again.store.documentOf(DocName.projects).projectItems.single.title,
        '完好版本',
        reason: '第二次启动必须还能看到数据 —— 这一条是本用例的重点',
      );
    });

    test('主文件不见了但有备份 → 从备份恢复并告警（不能当成全新安装）', () {
      storage.save(storeWith('第一份'), nowMillis: day);
      storage.save(storeWith('第二份'), nowMillis: day + 1);
      // 模拟「死在 删旧文件 → 改名 那个窗口里」：主文件没了，备份还在。
      // 这正是原子替换必须一步到位的原因 —— 两步法会留下这个可被观测到的空洞。
      storage.paths.storeFile.deleteSync();
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue);

      final report = storage.load(nowMillis: day + 2);

      expect(report.recoveredFromBackup, isNotNull);
      expect(report.quarantinedPaths, isEmpty, reason: '没有损坏文件需要隔离');
      expect(
        report.issues.errors.any((e) => e.contains('主数据文件不存在')),
        isTrue,
        reason: '「主文件凭空消失」是异常情况，必须是 error 而不只是 warning',
      );
      expect(
        report.store.documentOf(DocName.projects).projectItems.single.title,
        '第一份',
        reason: 'backup.1 就是上一次保存前的状态',
      );
      expect(storage.paths.storeFile.existsSync(), isTrue, reason: '恢复后要写回主文件');

      final again = storage.load(nowMillis: day + 3);
      expect(again.recoveredFromBackup, isNull, reason: '主文件已重建，不该反复恢复');
      expect(again.store.documentOf(DocName.projects).projectItems.single.title, '第一份');
    });

    test('主文件不见了且没有任何备份 → 空数据（全新安装就是这样，不该乱恢复）', () {
      storage.paths.ensureDirectories();

      final report = storage.load(nowMillis: day);

      expect(report.recoveredFromBackup, isNull);
      expect(report.store.documentOf(DocName.projects).items, isEmpty);
      expect(report.issues.errors, isEmpty, reason: '全新安装不是错误，不该吓唬用户');
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
