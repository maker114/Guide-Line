import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/json/canonical.dart';
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

  /// 非会话保存之间的最小轮转间隔。
  ///
  /// 2026-09-26 起，**不在编辑会话里**的保存按 `AppStorage.rotateMinIntervalMillis`
  /// 节流；所以"要看到轮转"的用例必须把时间戳拉开这么远，毫秒级的连存不再轮转
  /// （那正是节流本身要防的事）。
  const int step = AppStorage.rotateMinIntervalMillis;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_store_');
    storage = AppStorage(AppPaths(dir));
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 读主文件里那个项目的标题。
  String storeTitle() => StoreFile
      .parse(storage.paths.storeFile.readAsStringSync(encoding: utf8), DecodeIssues())
      .documentOf(DocName.projects)
      .projectItems
      .single
      .title;

  /// 读某一份滚动备份里那个项目的标题（没有这一份就返回 `null`）。
  String? rollingTitle(int index) {
    final file = storage.paths.rollingBackup(index);
    if (!file.existsSync()) return null;
    return StoreFile
        .parse(file.readAsStringSync(encoding: utf8), DecodeIssues())
        .documentOf(DocName.projects)
        .projectItems
        .single
        .title;
  }

  int rollingCount() =>
      storage.listBackups().where((b) => b.kind == BackupKind.rolling).length;

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

    test('主文件版本高于本应用：绝不覆盖，且明确告警（P0-1）', () {
      // 先写出真数据，再强制轮转一次，让磁盘上真的有一份备份可回退
      // （首次保存时主文件还不存在，没有"上一份"可轮转）
      storage.save(storeWith('旧的真数据'), nowMillis: day);
      storage.save(storeWith('旧的真数据'), nowMillis: day, forceRotate: true);
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue, reason: '先要有一份备份可回退');
      final backupsBefore = dir
          .listSync()
          .where((e) => e.uri.pathSegments.last.startsWith(AppPaths.backupPrefix))
          .length;

      // 主文件换成"未来版本"（用户降级安装 / 双端混用）
      final future = StoreFile.parse(
        storeWith('未来的数据').toCanonicalText(),
        DecodeIssues(),
      ).toJson();
      future['schemaVersion'] = StoreFile.currentSchemaVersion + 1;
      storage.paths.storeFile.writeAsStringSync(Canonical.documentText(future));

      final report = storage.load(nowMillis: day + step);

      // ① 不把"版本过高"当成功解析
      expect(
        report.storeLockedByNewerSchema,
        isTrue,
        reason: '版本高于本应用必须被识别出来，而不是当成一份合法的空数据',
      );
      // ② 主文件原样留在原地 —— 这是这条用例的核心
      expect(
        storage.paths.storeFile.readAsStringSync(),
        contains('未来的数据'),
        reason: '看不懂的文件也不能动它：一次启动就把用户数据换成空库是不可接受的',
      );
      // ③ 绝不写回空数据：任何滚动备份里都不该出现"备份.1 是空的"
      for (var i = 1; i <= AppPaths.rollingBackupCount; i += 1) {
        final file = storage.paths.rollingBackup(i);
        if (!file.existsSync()) continue;
        final parsed = StoreFile.parse(file.readAsStringSync(), DecodeIssues());
        expect(
          parsed.documentOf(DocName.projects).items,
          isNotEmpty,
          reason: '备份 $i 不该被空数据占掉',
        );
      }
      // ④ 用户必须被告知（否则界面上只是一个空库）
      expect(
        report.issues.errors.any((e) => e.contains('高于')),
        isTrue,
        reason: '要有一条能直接显示给用户的告警',
      );

      // ⑤ 用户接着做任何动作都会触发保存 —— 那时也绝不能覆盖（写盘守卫）
      storage.save(report.store, nowMillis: day + step * 2);
      expect(
        storage.paths.storeFile.readAsStringSync(),
        contains('未来的数据'),
        reason: '载入被锁住之后，任何一次保存都必须被拒绝',
      );
      final backupsAfter = dir
          .listSync()
          .where((e) => e.uri.pathSegments.last.startsWith(AppPaths.backupPrefix))
          .length;
      expect(
        backupsAfter,
        backupsBefore,
        reason: '被锁住时保存直接返回，连备份轮转都不该发生',
      );
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
      expect(text.contains('"schemaVersion": 3'), isTrue,
          reason: 'v3 起任务表不再写 next_task_ids（《数据契约》§7）');
    });
  });

  group('备份轮转', () {
    test('第二次保存会把上一份轮转成 backup.1', () {
      storage.save(storeWith('第一版'), nowMillis: day);
      storage.save(storeWith('第二版'), nowMillis: day + step);

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
      storage.save(storeWith('v2'), nowMillis: day + step);
      storage.save(storeWith('v3'), nowMillis: day + 2 * step);

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

    test('滚动备份最多 10 份，最老的一份被挤掉（移位不能把旧数据留下）', () {
      // 一次多存几版：移位现在走"改名"，所以要确认第 11 版进来时
      // 第 1 版被真正丢弃，而不是因为改名失败在原地留了个副本。
      // 每版之间拉开最小间隔，保证每一笔都真的轮转（节流见上面的说明）。
      for (var i = 0; i < 13; i += 1) {
        storage.save(storeWith('v$i'), nowMillis: day + i * step);
      }

      String? titleOf(int index) {
        final file = storage.paths.rollingBackup(index);
        if (!file.existsSync()) return null;
        return StoreFile
            .parse(file.readAsStringSync(encoding: utf8), DecodeIssues())
            .documentOf(DocName.projects)
            .projectItems
            .single
            .title;
      }

      // 存到第 13 版时，主文件是 v12，backup.1 是 v11，一路往前到 backup.10 是 v2
      expect(titleOf(1), 'v11');
      expect(titleOf(10), 'v2');
      expect(
        storage.paths.rollingBackup(AppPaths.rollingBackupCount + 1).existsSync(),
        isFalse,
        reason: '不该出现第 11 份滚动备份',
      );
      expect(titleOf(11), isNull);
      expect(
        storage.listBackups().where((b) => b.kind == BackupKind.rolling).length,
        AppPaths.rollingBackupCount,
      );
      expect(titleOf(10), isNot('v1'), reason: 'v1 已经被挤出窗口');
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

    test('会话内：多笔写入只留一份备份，它存的是"进页面之前"的状态', () {
      storage.save(storeWith('会话前'), nowMillis: day);
      expect(rollingCount(), 0, reason: '那时磁盘上还没有"上一份"');

      storage.beginEditSession();
      storage.save(storeWith('会话中一'), nowMillis: day + 1000);
      storage.save(storeWith('会话中二'), nowMillis: day + 2000);
      storage.save(storeWith('会话中三'), nowMillis: day + 3000);

      expect(rollingCount(), 1, reason: '一段编辑会话只留一份备份');
      expect(rollingTitle(1), '会话前', reason: '这一份必须是"进页面之前"的存档');
      expect(storeTitle(), '会话中三', reason: '主文件照旧每一笔都写');
    });

    test('会话结束后再进一次页面，允许再留一份', () {
      storage.save(storeWith('v1'), nowMillis: day);

      storage.beginEditSession();
      storage.save(storeWith('v2'), nowMillis: day + 1000);
      storage.endEditSession();
      expect(rollingCount(), 1);

      storage.beginEditSession();
      storage.save(storeWith('v3'), nowMillis: day + 2000);
      storage.endEditSession();

      expect(rollingCount(), 2);
      expect(rollingTitle(1), 'v2', reason: '第二段会话的备份是"这段之前"的状态');
      expect(rollingTitle(2), 'v1');
    });

    test('卡住的会话会过期：不活动够久之后备份照常轮转（P1-6）', () {
      storage.save(storeWith('v1'), nowMillis: day);

      // 会话被"打开"却再也没配对关闭（predictive back 取消、路由被非对称移除……
      // 真机上 App 切后台不重启进程，这个状态能持续好几天）
      storage.beginEditSession();
      storage.save(storeWith('v2'), nowMillis: day + 1000);
      expect(rollingCount(), 1, reason: '会话内的第一笔写入会留一份');

      // 会话内再改几笔：同会话不重复轮转
      storage.save(storeWith('v3'), nowMillis: day + 2000);
      expect(rollingCount(), 1);

      // 隔了很久（远超会话不活动上限）之后再保存：
      // 旧实现因为 _rotatedInSession 一直为真，这里会**永远不再轮转备份**
      final muchLater = day + 2000 + AppStorage.editSessionIdleLimitMillis + step;
      storage.save(storeWith('v4'), nowMillis: muchLater);

      expect(
        rollingCount(),
        greaterThan(1),
        reason: '卡住的会话不该让备份永远停更',
      );
      expect(storeTitle(), 'v4', reason: '主文件照旧每一笔都写');
    });

    test('不在会话中：按最小间隔节流（不足间隔的保存不轮转）', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + 1000);
      expect(rollingCount(), 0, reason: '距上次轮转只有 1 秒，不该再挤一份');

      storage.save(storeWith('v3'), nowMillis: day + step);
      expect(rollingCount(), 1, reason: '够最小间隔了才轮转');
      expect(rollingTitle(1), 'v2', reason: '轮转的是那一刻的主文件（v2）');
      expect(storeTitle(), 'v3');
    });

    test('进页面但一笔都没写：备份数不变（轮转发生在第一笔写入时）', () {
      storage.save(storeWith('会话前'), nowMillis: day);
      final before = storage.listBackups().length;

      storage.beginEditSession();
      storage.endEditSession();

      expect(storage.listBackups().length, before, reason: '什么都没改就不该留下存档');
    });

    test('日快照行为不变：会话里第一次轮转也会留当天那一份', () {
      storage.save(storeWith('今天的开头'), nowMillis: day);
      storage.beginEditSession();
      storage.save(storeWith('会话内的改动'), nowMillis: day + 1000);
      storage.endEditSession();

      final dailies =
          storage.listBackups().where((b) => b.kind == BackupKind.daily).toList();
      expect(dailies, hasLength(1), reason: '同一天只留一份日快照');
    });

    test('从备份恢复仍然强制轮转（刚轮转过也要先把当前数据留住）', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.beginEditSession();
      storage.save(storeWith('v2'), nowMillis: day + 1000); // 会话内第一次 → 轮转
      storage.endEditSession();

      final target = storage.paths.rollingBackup(1).path; // = v1
      // 距上次轮转只有 1 秒：不走 force 的话这一步会什么都不留
      storage.restoreFromBackup(target, nowMillis: day + 2000);

      expect(rollingTitle(1), 'v2', reason: '恢复前的数据必须进了 backup.1');
      expect(storeTitle(), 'v1', reason: '主文件换成了要恢复的那一份');
    });

    test('forceRotate 不等最小间隔（「立即备份一份」按的就是它）', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + 1, forceRotate: true);

      expect(rollingCount(), 1);
      expect(rollingTitle(1), 'v1');
    });

    test('备份标签给的是时间点与条数，不再写"几次保存前"', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + step);

      final entries = storage.listBackups();
      final rolling = entries.firstWhere((e) => e.kind == BackupKind.rolling);
      expect(rolling.label, contains('上一份'));
      expect(rolling.label, isNot(contains('次保存前')));
      expect(rolling.label, contains('· 1 条'));
      expect(rolling.recordCount, 1, reason: '这份备份里就一个项目');

      final daily = entries.firstWhere((e) => e.kind == BackupKind.daily);
      expect(daily.label, startsWith('日快照 '));
      expect(daily.label, contains('· 1 条'));
      expect(daily.recordCount, 1);
    });

    test('备份读不出来时 recordCount 给 null（不猜、也不写成 0 条）', () {
      storage.save(storeWith('数据'), nowMillis: day);
      storage.save(storeWith('数据二'), nowMillis: day + step);
      storage.paths.rollingBackup(1).writeAsStringSync('{"broken": ');

      final rolling = storage
          .listBackups()
          .firstWhere((b) => b.kind == BackupKind.rolling);
      expect(rolling.recordCount, isNull);
      expect(rolling.label, isNot(contains('条')), reason: '数不出条数就别写条数');
      expect(rolling.path, contains('guideline.backup.1.json'), reason: '这一份仍然要列出来');
    });

    test('备份列表按"滚动备份在前、日快照在后"给出可读标签', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + step);

      final entries = storage.listBackups();
      expect(entries.first.kind, BackupKind.rolling);
      expect(entries.first.label, contains('上一份'));
      expect(entries.any((e) => e.kind == BackupKind.daily && e.label.contains('日快照')), isTrue);
    });
  });

  group('删除备份', () {
    test('多份备份时，删掉指定的那一份，其余留着', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + step);
      storage.save(storeWith('v3'), nowMillis: day + 2 * step);

      final rolling = storage
          .listBackups()
          .where((b) => b.kind == BackupKind.rolling)
          .toList(growable: false);
      expect(rolling.length, greaterThanOrEqualTo(2), reason: '先得有得删');

      final victim = rolling.first;
      expect(storage.deleteBackup(victim.path), isNull, reason: '返回 null 表示删成功');
      expect(File(victim.path).existsSync(), isFalse, reason: '文件本身要没了');

      final after = storage.listBackups();
      expect(after.any((b) => b.path == victim.path), isFalse, reason: '列表里也不该再有');
      expect(after.length, greaterThan(0), reason: '其余备份必须还在');
    });

    test('只剩一份时拒绝删除（不把安全网清空）', () {
      // 首次保存只留日快照；再存一次才会轮转出滚动备份
      storage.save(storeWith('第一版'), nowMillis: day);
      storage.save(storeWith('第二版'), nowMillis: day + step);

      final rolling = storage
          .listBackups()
          .where((b) => b.kind == BackupKind.rolling)
          .toList(growable: false);
      expect(rolling.length, 1);
      // 先把滚动备份删掉，剩下唯一的一份日快照
      expect(storage.deleteBackup(rolling.single.path), isNull);

      final only = storage.listBackups().single;
      expect(only.kind, BackupKind.daily, reason: '剩下的应该是日快照');

      final error = storage.deleteBackup(only.path);
      expect(error, isNotNull, reason: '要给出拒绝原因');
      expect(error, contains('至少保留一份'));
      expect(File(only.path).existsSync(), isTrue, reason: '拒绝之后文件必须原样在');
      expect(storage.listBackups().length, 1);
    });

    test('只认列出来的备份：主文件 / 偏好文件 / 随便一个路径都删不动', () {
      storage.save(storeWith('数据'), nowMillis: day);
      storage.save(storeWith('数据二'), nowMillis: day + step);
      final storeFile = storage.paths.storeFile;
      final prefsFile = storage.paths.prefsFile;
      final before = storage.listBackups().length;
      expect(before, greaterThanOrEqualTo(2), reason: '这一例要验的是"不是备份"，不是"最后一份"');

      for (final path in <String>[
        storeFile.path,
        prefsFile.path,
        '${dir.path}${Platform.pathSeparator}根本没有这个文件.json',
      ]) {
        expect(storage.deleteBackup(path), isNotNull, reason: '$path 不该被当成备份删掉');
      }

      expect(File(storeFile.path).existsSync(), isTrue, reason: '主文件必须毫发无损');
      expect(storage.listBackups().length, before, reason: '真正的备份也没被动过');
    });

    test('删掉一份之后仍然能正常保存与恢复（不会把轮转搞乱）', () {
      storage.save(storeWith('v1'), nowMillis: day);
      storage.save(storeWith('v2'), nowMillis: day + step);
      storage.save(storeWith('v3'), nowMillis: day + 2 * step);

      final victim = storage
          .listBackups()
          .firstWhere((b) => b.kind == BackupKind.rolling);
      expect(storage.deleteBackup(victim.path), isNull);

      // 删完之后再存一次：轮转照常，主文件仍可读
      storage.save(storeWith('v4'), nowMillis: day + 3 * step);
      final report = storage.load();
      expect(report.store.documentOf(DocName.projects).projectItems.single.title, 'v4');
      expect(victim.path == storage.paths.storeFile.path, isFalse);
    });
  });

  group('交接说明导出', () {
    test('文件名是 handoff-<项目名>-时间戳.md，且项目名里的危险字符被收掉', () {
      final file = storage.writeHandoffExport(
        day,
        '# 项目：示例\n',
        projectTitle: '重构/知识库: 第二版',
      );

      final name = file.uri.pathSegments.last;
      expect(name.startsWith('handoff-'), isTrue);
      expect(name.endsWith('.md'), isTrue);
      expect(name, contains('20260906'));
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(':')));
      expect(name, isNot(contains(' ')));
      expect(file.readAsStringSync(encoding: utf8), '# 项目：示例\n');
    });

    test('没有项目名也能导出（文件名只留前缀与时间）', () {
      final file = storage.writeHandoffExport(day, '内容\n');
      final name = file.uri.pathSegments.last;
      expect(name.startsWith('handoff-2'), isTrue, reason: '紧接着就是日期');
      expect(name.endsWith('.md'), isTrue);
    });

    test('交接说明**不被导出轮转清理**（它是用户特意生成的）', () {
      // 先造出超过保留数的整库导出，触发 _pruneExports
      for (var i = 0; i < AppStorage.exportKeepCount + 3; i += 1) {
        storage.writeExport(<int>[1, 2, 3], nowMillis: day + i * 1000);
      }
      final handoff = storage.writeHandoffExport(day, '# 说明\n');

      // 再写一次整库导出，让清理逻辑跑一遍
      storage.writeExport(<int>[4, 5, 6], nowMillis: day + 999000);

      expect(
        handoff.existsSync(),
        isTrue,
        reason: 'handoff-* 不在 listExports 的筛选范围内，不该被轮转删掉',
      );
      expect(
        storage.listExports().length,
        AppStorage.exportKeepCount,
        reason: '整库导出仍然按保留份数轮转',
      );
    });

    test('交接说明写两次是两份不同文件（按秒区分）', () {
      final a = storage.writeHandoffExport(day, '第一份\n', projectTitle: '甲');
      final b = storage.writeHandoffExport(day + 1000, '第二份\n', projectTitle: '甲');
      expect(a.path, isNot(b.path));
      expect(a.existsSync() && b.existsSync(), isTrue);
    });
  });

  group('备份列表的口径（P1-8）', () {
    test('没有记录的备份：标成"无法解析"，而且拒绝拿它恢复', () {
      storage.save(storeWith('真数据'), nowMillis: day);
      storage.save(storeWith('真数据'), nowMillis: day, forceRotate: true);
      // 把那份备份换成"合法 JSON 但没有任何记录"的内容
      final victim = storage.paths.rollingBackup(1);
      victim.writeAsStringSync('[1,2,3]');

      final entry = storage.listBackups().firstWhere((b) => b.path == victim.path);
      expect(
        entry.recordCount,
        isNull,
        reason: '数不出记录要报 null —— 写成"0 条"看起来像一份空但合法的备份，比不写还误导',
      );
      expect(entry.label, contains('无法解析'));

      expect(
        () => storage.restoreFromBackup(victim.path, nowMillis: day + step),
        throwsA(isA<StateError>()),
        reason: '拿一份空备份恢复等于把主文件换成空数据，必须拦住',
      );
    });
  });

  group('备份时间口径（P1-10）', () {
    test('文件名日期在未来，也不该被当成最新而挤掉真正最近的', () {
      AppPaths(dir).ensureDirectories();

      // 不通过 save 造，直接写两份日快照：一份"未来日期"但更旧，一份更早的日期但更新
      final fake = AppPaths(dir).dailyBackup('20991231');
      fake.writeAsStringSync(storeWith('未来日期的假快照').toCanonicalText());
      fake.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(day));

      final real = AppPaths(dir).dailyBackup('20260901');
      real.writeAsStringSync(storeWith('上个月的真快照').toCanonicalText());
      real.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(day + step));

      // 主文件不在 → 走"从最新的备份恢复"这条路
      final report = storage.load(nowMillis: day + 2 * step);

      expect(
        report.recoveredFromBackup,
        isNotNull,
        reason: '有可用备份就该恢复',
      );
      final titles = report.store
          .documentOf(DocName.projects)
          .projectItems
          .map((p) => p.title)
          .toList();
      expect(
        titles,
        contains('上个月的真快照'),
        reason: '按修改时间选最新的那份；按文件名字符串排会选中"20991231"那份（P1-10），实际=$titles',
      );
    });
  });

  group('损坏与恢复', () {
    test('主文件损坏 → 隔离现场 + 从备份自动恢复', () {
      storage.save(storeWith('完好版本'), nowMillis: day);
      storage.save(storeWith('最新版本'), nowMillis: day + step);
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
      storage.save(storeWith('第二份'), nowMillis: day + step);
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

    test('主文件不是合法 UTF-8 → 不崩，按损坏隔离并从备份恢复（P1-2）', () {
      // 先落到磁盘一份真数据；第二次强制轮转才会真的留下备份
      // （首次保存时主文件还不存在，没有"上一份"可轮转）
      storage.save(storeWith('真数据'), nowMillis: day);
      storage.save(storeWith('真数据'), nowMillis: day, forceRotate: true);
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue);

      // 主文件写成一串非法 UTF-8 —— 掉电后半截写入的典型产物。
      // 旧实现里 `readAsStringSync` 裸调，异常直接冒到 main，用户看到的是启动崩溃。
      storage.paths.storeFile.writeAsBytesSync(<int>[0xFF, 0xFE, 0x00, 0x01, 0xC3, 0x28]);

      late LoadReport report;
      expect(
        () => report = storage.load(nowMillis: day + step),
        returnsNormally,
        reason: '读不出来也只是"损坏"的一种，绝不能让启动崩掉',
      );
      expect(report.quarantinedPaths, hasLength(1), reason: '现场要隔离保留');
      final titles = report.store
          .documentOf(DocName.projects)
          .projectItems
          .map((p) => p.title)
          .toList();
      expect(
        titles.contains('真数据'),
        isTrue,
        reason: '主文件读不了时应当能从备份（滚动备份或日快照）恢复出真数据，实际=$titles',
      );
    });

    test('主文件损坏 + 备份也没有可用记录 → 不用空数据覆盖（P0-2）', () {
      // 主文件损坏：不是合法 JSON
      storage.paths.ensureDirectories();
      storage.paths.storeFile.writeAsStringSync('{"broken": ');

      // 唯一的滚动备份是"能被 parse 收下、但里面没有任何记录"的内容。
      // 这正是原来的漏洞：守门条件 `documents.isNotEmpty` 恒为真，
      // 于是这份垃圾会被当成恢复来源，用空数据盖掉刚隔离走的主文件，
      // 还向用户报"已从备份恢复"—— 用户以为救回来了，其实什么都没了。
      storage.paths.rollingBackup(1).writeAsStringSync('[1,2,3]');
      // 日快照也放一份同样没记录的（否则它会被当成合法的恢复来源）
      final d = DateTime.fromMillisecondsSinceEpoch(day);
      String two(int v) => v.toString().padLeft(2, '0');
      storage.paths
          .dailyBackup('${d.year}${two(d.month)}${two(d.day)}')
          .writeAsStringSync('{"schemaVersion":3,"savedAt":1,"collections":{}}');

      final report = storage.load(nowMillis: day + step);

      expect(
        report.recoveredFromBackup,
        isNull,
        reason: '一份没有记录的"备份"不是恢复来源',
      );
      expect(
        storage.paths.storeFile.existsSync() &&
            storage.paths.storeFile.readAsStringSync() == '[1,2,3]',
        isFalse,
        reason: '绝不能拿空数据把主文件换掉（损坏的主文件应被隔离走，而不是被垃圾覆盖）',
      );
      expect(storage.paths.rollingBackup(1).existsSync(), isTrue,
          reason: '那份坏备份不该被删掉 —— 留着现场才有诊断余地');
      expect(report.store.documentOf(DocName.projects).items, isEmpty);
    });

    test('从备份恢复：能把指定备份写回主文件，且当前数据先被轮转走', () {
      storage.save(storeWith('要保留的旧数据'), nowMillis: day);
      storage.save(storeWith('误操作后的数据'), nowMillis: day + step);

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

    test('恢复报告带得上界面要用的名字：恢复来源与隔离文件（Q16 的告警条就靠它）', () {
      storage.save(storeWith('完好版本'), nowMillis: day);
      storage.save(storeWith('最新版本'), nowMillis: day + step);
      storage.paths.storeFile.writeAsStringSync('{"broken": ');

      final report = storage.load(nowMillis: day + 2 * step);

      expect(report.recoveredFromBackup, isNotNull);
      expect(
        report.recoveredFromBackup,
        endsWith('guideline.backup.1.json'),
        reason: '告警里要说清"从哪一份备份恢复的"',
      );
      expect(report.quarantinedPaths, hasLength(1));
      expect(
        report.quarantinedPaths.single,
        contains('guideline.json.corrupt.'),
        reason: '隔离文件名要能直接显示给用户',
      );
      expect(report.hasProblems, isTrue, reason: '上层据此重新拉响导出提醒');
    });
  });

  group('实现计划的历史正文（私有存档）', () {
    test('存 / 读 / 销：只认项目 id，互不串味', () {
      storage.saveImplementationSnapshot('p-1', '第一版正文');
      storage.saveImplementationSnapshot('p-2', '另一个项目的正文');

      expect(storage.readImplementationSnapshot('p-1'), '第一版正文');
      expect(storage.readImplementationSnapshot('p-2'), '另一个项目的正文');
      expect(storage.readImplementationSnapshot('没存过'), isNull);

      storage.clearImplementationSnapshot('p-1');
      expect(storage.readImplementationSnapshot('p-1'), isNull);
      expect(storage.readImplementationSnapshot('p-2'), '另一个项目的正文',
          reason: '销掉一个项目不该动别的项目');
    });

    test('它不进主数据文件、也不进备份（只是一次反悔用的留档）', () {
      storage.save(storeWith('项目'), nowMillis: day);
      storage.save(storeWith('项目·再改'), nowMillis: day + step);
      final backupsBefore = storage.listBackups().map((b) => b.sizeBytes).toList();
      // 前置：列表必须非空（T-5）—— 否则下面"列表没变"与 `every(...)` 在空集合上恒真，
      // 用例名承诺的"不进备份"根本没被验证过。
      expect(backupsBefore, isNotEmpty, reason: '先要真的有备份，才谈得上"没被动过"');

      storage.saveImplementationSnapshot('p-项目', '一段很长很长很长的旧正文');

      expect(
        storage.paths.storeFile.readAsStringSync(encoding: utf8).contains('一段很长很长很长'),
        isFalse,
        reason: '私有存档不能混进数据文件',
      );
      expect(storage.listBackups().map((b) => b.sizeBytes).toList(), backupsBefore);
      expect(
        storage.listBackups().every((b) => b.recordCount == 1),
        isTrue,
        reason: '备份的条数口径不该被这份存档影响',
      );
      final history = File(
        '${dir.path}${Platform.pathSeparator}'
        '${AppStorage.implementationHistoryFileName}',
      );
      expect(history.existsSync(), isTrue, reason: '它落在应用私有目录里');
    });

    test('存档坏了只当"没有历史"，不抛异常', () {
      storage.saveImplementationSnapshot('p-1', '正文');
      File(
        '${dir.path}${Platform.pathSeparator}'
        '${AppStorage.implementationHistoryFileName}',
      ).writeAsStringSync('{ 坏掉的');

      expect(storage.readImplementationSnapshot('p-1'), isNull);
      // 还能继续写：坏文件被下一次保存整份覆盖
      storage.saveImplementationSnapshot('p-1', '新的一版');
      expect(storage.readImplementationSnapshot('p-1'), '新的一版');
    });
  });

  group('界面偏好', () {
    test('独立文件保存与读回，且不触碰主数据文件', () {
      storage.save(storeWith('项目'), nowMillis: day);
      final before = storage.paths.storeFile.readAsStringSync(encoding: utf8);

      storage.savePrefs(
        UiPrefs.empty.withExpanded('p-1', expanded: false).copyWith(lastTabIndex: 2),
      );

      final report = storage.load();
      expect(report.prefs.isExpanded('p-1'), isFalse);
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
