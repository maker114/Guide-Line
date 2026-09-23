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
      final before = storage.paths.storeFile.readAsStringSync();

      storage.writeExport(
        ExportCodec.encode(sampleStore(), exportedAt: Ids.nowMillis()),
        nowMillis: Ids.nowMillis(),
      );

      expect(storage.paths.storeFile.readAsStringSync(), before);
    });
  });
}
