import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/json/store_file.dart';
import 'package:guideline/core/models/github_backup_config.dart';
import 'package:guideline/core/store/export_codec.dart';
import 'package:guideline/platform/github_backup_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 走真实 [HttpGitHubBackupGateway] 的两条**只在特定响应下才出现**的路径。
///
/// 这一页存在的理由与 `AiTextGenerator` 那个口子一样具体：这两件事都不是
/// "想清楚就行"的 —— GitHub 对一个 1 MB 以上的文件回的是**空 content**
/// （`encoding: none`），而 Contents API 对"仓库 / 权限不对"与"文件还没推过"
/// 回的是**同一个 404**。没有假响应，就验不出我们分开处理了它们（ADR-090）。
void main() {
  const GitHubBackupConfig config = GitHubBackupConfig(
    enabled: true,
    owner: 'maker114',
    repo: 'guideline-backup',
    branch: 'main',
    path: GitHubBackupConfig.defaultPath,
  );
  const String token = 'ghp_token';
  const int t1 = 1788652800000; // 2026-09-23 08:00 UTC

  /// 一份真的能解开的备份（走与推送完全相同的编码，免得验的是"我以为的形状"）。
  List<int> realBackupBytes() =>
      ExportCodec.encode(StoreFile.empty(), exportedAt: t1);

  /// 大文件时 GitHub 给的元数据：**content 是空串、encoding 是 none**，
  /// 但 sha 与 size 照给。旧写法 base64.decode('') 不抛错，于是静默失效。
  String bigFileMetadata(int size, {String sha = 'blob-big'}) => jsonEncode({
        'sha': sha,
        'size': size,
        'encoding': 'none',
        'content': '',
        'name': 'guideline-latest.json.gz',
      });

  test('文件超过 1 MB：默认媒体类型只回空 content，就换 git/blobs 再读一次', () async {
    final bytes = realBackupBytes();
    final requests = <http.Request>[];

    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.contains('/git/blobs/')) {
          return http.Response(
            jsonEncode({
              'sha': 'blob-big',
              'size': bytes.length,
              'encoding': 'base64',
              'content': base64.encode(bytes),
            }),
            200,
          );
        }
        return http.Response(bigFileMetadata(bytes.length), 200);
      }),
    );

    final remote = await gateway.readBackup(config: config, token: token);

    expect(remote, isNotNull);
    expect(remote!.sha, 'blob-big');
    expect(remote.bytes, bytes);
    expect(remote.readable, isTrue);
    expect(requests, hasLength(2));
    expect(requests.first.headers['Accept'], 'application/vnd.github+json');
    expect(
      requests.last.url.path,
      '/repos/maker114/guideline-backup/git/blobs/blob-big',
      reason: '补读走 Git Blobs API：raw 那条路实测 1.38 MB 传不完就被掐断',
    );
    expect(
      requests.last.headers['Accept'],
      'application/vnd.github+json',
      reason: 'blob 回来的还是 JSON，内容是 base64 字段',
    );
  });

  test('blob 回的是 utf-8（纯文本）：按文本字节用', () async {
    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async {
        if (request.url.path.contains('/git/blobs/')) {
          return http.Response(
            jsonEncode({
              'sha': 'blob-text',
              'encoding': 'utf-8',
              'content': 'guideline',
            }),
            200,
          );
        }
        return http.Response(bigFileMetadata(2 * 1024 * 1024), 200);
      }),
    );

    final remote = await gateway.readBackup(config: config, token: token);

    expect(utf8.decode(remote!.bytes), 'guideline');
  });

  test('1 MB 以内：base64 就在响应里，不多花那一个请求', () async {
    final bytes = realBackupBytes();
    final requests = <http.Request>[];

    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'sha': 'blob-small',
            'size': bytes.length,
            'encoding': 'base64',
            'content': base64.encode(bytes),
          }),
          200,
        );
      }),
    );

    final remote = await gateway.readBackup(config: config, token: token);

    expect(remote!.bytes, bytes);
    expect(requests, hasLength(1), reason: '小文件不该多走一次 blob');
  });

  test('git/blobs 那条路也被拒（403）：单列一条"太大"，不混成"读不出数据"', () async {
    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async {
        if (request.url.path.contains('/git/blobs/')) {
          return http.Response('{"message":"too large"}', 403);
        }
        return http.Response(bigFileMetadata(2 * 1024 * 1024), 200);
      }),
    );

    await expectLater(
      gateway.readBackup(config: config, token: token),
      throwsA(
        isA<GitHubBackupException>().having(
          (error) => error.message,
          'message',
          contains('太大'),
        ),
      ),
    );
  });

  test('文件还没推过：readBackup 回 null（"没有"不是错误）', () async {
    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async => http.Response('{}', 404)),
    );

    expect(await gateway.readBackup(config: config, token: token), isNull);
  });

  test('仓库在：读到全名、私有与默认分支', () async {
    final gateway = HttpGitHubBackupGateway(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'full_name': 'Maker114/Guideline-Backup',
            'private': true,
            'default_branch': 'trunk',
          }),
          200,
        ),
      ),
    );

    final repo = await gateway.describeRepository(config: config, token: token);

    expect(repo.fullName, 'Maker114/Guideline-Backup');
    expect(repo.isPrivate, isTrue);
    expect(repo.defaultBranch, 'trunk');
  });

  test('仓库 / 权限不对：describeRepository 抛出的是可读的那一句', () async {
    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async => http.Response('{"message":"Not Found"}', 404)),
    );

    await expectLater(
      gateway.describeRepository(config: config, token: token),
      throwsA(
        isA<GitHubBackupException>().having(
          (error) => error.message,
          'message',
          allOf(contains('404'), contains('仓库')),
        ),
      ),
    );
  });

  group('读大文件的超时按体积放宽', () {
    // 实测：1.38 MB 的备份在一条慢链路上要读 68 秒。固定 30 秒会把"正在读"
    // 掐成「请求超时」，用户照样拿不到备份 —— 所以这条线必须跟着体积走。
    test('小文件还是 30 秒那条线', () {
      expect(
        HttpGitHubBackupGateway.readBudgetFor(8 * 1024),
        HttpGitHubBackupGateway.timeout,
      );
      expect(
        HttpGitHubBackupGateway.readBudgetFor(null),
        HttpGitHubBackupGateway.timeout,
        reason: '元数据没给 size 时不猜，用默认那条线',
      );
      expect(
        HttpGitHubBackupGateway.readBudgetFor(0),
        HttpGitHubBackupGateway.timeout,
      );
    });

    test('1.38 MB 给到两分钟以上，慢网也读得完', () {
      final budget = HttpGitHubBackupGateway.readBudgetFor(1383786);

      expect(budget.inSeconds, greaterThanOrEqualTo(68), reason: '实测那一次用了 68 秒');
      expect(budget.inSeconds, lessThanOrEqualTo(150));
    });

    test('再大也不超过 5 分钟上限', () {
      expect(
        HttpGitHubBackupGateway.readBudgetFor(100 * 1024 * 1024),
        HttpGitHubBackupGateway.maxReadTimeout,
      );
    });
  });
}
