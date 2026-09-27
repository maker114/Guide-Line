import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/ids.dart';
import 'package:guideline/core/json/document.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/entity.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/inspiration.dart';
import 'package:guideline/core/models/project.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/core/store/app_storage.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/core/store/ui_prefs.dart';

/// 导出 / 导入的编解码与文件轮转。
///
/// 这是"数据离开手机"的唯一通道，所以边界情况必须钉死：
/// 自己的导出能原样读回、电脑端旧格式能读、垃圾文件**不会**被当成有效数据。
void main() {
  Project project(String id, String title) => Project(
        id: id,
        title: title,
        purpose: '目的',
        implementation: '实现',
        date: '2026-09-23',
        status: NodeStatus.pending,
        archived: false,
        parentProjectId: null,
        order: 1000,
        completedAt: null,
        createdAt: 1788652800000,
        updatedAt: 1788652800000,
        deleted: false,
      );

  Inspiration inspiration(String id, String text) => Inspiration(
        id: id,
        text: text,
        projectId: null,
        status: InspirationStatus.pending,
        mergedInto: null,
        mergedAt: null,
        createdAt: 1788652800000,
        updatedAt: 1788652800000,
        deleted: false,
      );

  StoreFile sampleStore() => StoreFile(
        savedAt: 1788652800000,
        documents: <DocName, Document>{
          for (final name in DocName.values) name: Document.empty(name),
          DocName.projects: Document(
            name: DocName.projects,
            items: <Entity>[project('p1', '指南线')],
          ),
          DocName.inspirations: Document(
            name: DocName.inspirations,
            items: <Entity>[inspiration('i1', '速记优先')],
          ),
        },
      );

  group('对外常量用字面量钉住（T-2）', () {
    // 这几个值有一个共同点：**改了它们，一次 `flutter test` 都不会红**。
    // 原来的断言写的是 `expect(map['app'], ExportCodec.appName)` —— 拿常量断言常量，
    // 自指、恒真。可它们是**对外格式的一部分**（导出文件被别的程序读、被别的版本读），
    // 属于"一旦改了就是破坏性变更"，所以用字面量钉死。
    test('导出文件的 app / kind 字面量', () {
      expect(ExportCodec.appName, 'GuideLine');
      expect(ExportCodec.fullExportKind, 'full-export');
    });

    test('导出保留份数字面量', () {
      // 用例名里一直写着"只保留最近 5 份"，但值本身从未被钉住
      expect(AppStorage.exportKeepCount, 5);
    });

    test('界面偏好：背景不透明度的默认值', () {
      // 界面上的滑杆初值依赖它；改了不会有任何测试失败
      expect(UiPrefs.defaultBackgroundOpacity, 0.30);
    });
  });

  group('导出编码', () {
    test('编码结果是 gzip，解出来是自描述 JSON', () {
      final bytes = ExportCodec.encode(sampleStore(), exportedAt: 1788652800000);
      final text = utf8.decode(gzip.decode(bytes));
      final map = json.decode(text) as Map<String, dynamic>;

      expect(map['app'], ExportCodec.appName);
      expect(map['kind'], ExportCodec.fullExportKind);
      expect(map['exportedAt'], 1788652800000);
      expect(map['schemaVersion'], StoreFile.currentSchemaVersion);
      expect(map.containsKey('collections'), isTrue);
    });

    test('自己的导出能原样读回（四类集合条数一致）', () {
      final store = sampleStore();
      final bytes = ExportCodec.encode(store, exportedAt: 1788652800000);
      final issues = DecodeIssues();
      final payload = ExportCodec.decode(bytes, issues);

      expect(payload.readable, isTrue);
      expect(payload.exportedAt, 1788652800000);
      expect(issues.errors, isEmpty);
      for (final name in DocName.values) {
        expect(
          payload.store.documentOf(name).items.length,
          store.documentOf(name).items.length,
          reason: '$name 条数应一致',
        );
      }
      expect(payload.total, 2);
      expect(payload.countSummary.contains('项目 1'), isTrue);
      expect(payload.countSummary.contains('灵感 1'), isTrue);
    });
  });

  group('导入解码', () {
    test('未压缩的明文 JSON 也能读（gzip 坏掉后仍可人工抢救）', () {
      final plain = utf8.encode(sampleStore().toCanonicalText());
      final payload = ExportCodec.decode(plain, DecodeIssues());

      expect(payload.readable, isTrue);
      expect(payload.store.documentOf(DocName.projects).items.length, 1);
      expect(payload.exportedAt, isNull, reason: '明文没有 exportedAt 字段');
    });

    test('兼容电脑端 v1 四文档信封', () {
      final legacy = <String, dynamic>{
        'savedAt': 1788652800000,
        'projects.json': <String, dynamic>{
          'version': 3,
          'updated_at': 1788652800000,
          'last_tx_id': 'tx-1',
          'payload': <String, dynamic>{
            'items': <dynamic>[project('p1', '旧数据').toJson()],
          },
        },
      };
      final payload = ExportCodec.decode(
        utf8.encode(json.encode(legacy)),
        DecodeIssues(),
      );

      expect(payload.readable, isTrue);
      final items = payload.store.documentOf(DocName.projects).items;
      expect(items.length, 1);
      expect((items.first as Project).title, '旧数据');
    });

    test('垃圾文件不会被当成有效数据（宁可拒绝，也不要写入半个库）', () {
      final issues = DecodeIssues();
      final payload = ExportCodec.decode(utf8.encode('这不是 JSON'), issues);

      expect(payload.readable, isFalse);
      expect(issues.errors, isNotEmpty);
    });

    test('空对象被拒绝：没有 collections 就没有可导入的内容', () {
      final payload = ExportCodec.decode(utf8.encode('{}'), DecodeIssues());
      expect(payload.readable, isFalse);
    });
  });

  group('导出文件落盘', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('guideline_export_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('导出文件写进 exports 目录，名字带时间戳', () {
      final storage = AppStorage(AppPaths(tempDir));
      final store = sampleStore();
      final bytes = ExportCodec.encode(store, exportedAt: 1788652800000);
      final file = storage.writeExport(bytes, nowMillis: 1788652800000);

      expect(file.existsSync(), isTrue);
      expect(file.path.contains(AppPaths.exportsDirName), isTrue);
      expect(file.uri.pathSegments.last.startsWith('guideline-'), isTrue);
      expect(file.uri.pathSegments.last.endsWith('.json.gz'), isTrue);

      // 写出去的字节能被自己读回来
      final payload = ExportCodec.decode(file.readAsBytesSync(), DecodeIssues());
      expect(payload.readable, isTrue);
      expect(payload.store.documentOf(DocName.inspirations).items.length, 1);
    });

    test('导出文件只保留最近 5 份（手滑选错目标时有得退）', () {
      final storage = AppStorage(AppPaths(tempDir));
      for (var i = 0; i < 8; i += 1) {
        storage.writeExport(
          ExportCodec.encode(sampleStore(), exportedAt: 1788652800000 + i * 1000),
          nowMillis: 1788652800000 + i * 1000,
        );
      }
      expect(storage.listExports().length, AppStorage.exportKeepCount);
    });

    test('导出不会碰主数据文件与备份', () {
      final storage = AppStorage(AppPaths(tempDir));
      storage.save(sampleStore(), nowMillis: 1788652800000);
      // 造出一份备份（T-5）：用例名承诺"与备份"，而原来正文一次都没调 listBackups()
      storage.save(sampleStore(), nowMillis: 1788652800000, forceRotate: true);
      final before = storage.paths.storeFile.readAsStringSync();
      final backupsBefore = storage
          .listBackups()
          .map((b) => <Object?>[b.path, b.sizeBytes, b.recordCount])
          .toList();
      expect(backupsBefore, isNotEmpty, reason: '先要真的有备份可断言');

      storage.writeExport(
        ExportCodec.encode(sampleStore(), exportedAt: Ids.nowMillis()),
        nowMillis: Ids.nowMillis(),
      );

      expect(storage.paths.storeFile.readAsStringSync(), before);
      expect(
        storage
            .listBackups()
            .map((b) => <Object?>[b.path, b.sizeBytes, b.recordCount])
            .toList(),
        backupsBefore,
        reason: '导出只在私有目录里多一个文件，不该动数据、也不该动备份',
      );
    });
  });
}
