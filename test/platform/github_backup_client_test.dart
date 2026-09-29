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

  test('文件超过 1 MB：默认媒体类型只回空 content，就换 raw 再读一次', () async {
    final bytes = realBackupBytes();
    final requests = <http.Request>[];

    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async {
        requests.add(request);
        if (request.headers['Accept'] == 'application/vnd.github.raw') {
          return http.Response.bytes(bytes, 200);
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
    expect(requests.last.headers['Accept'], 'application/vnd.github.raw');
    expect(
      requests.last.url.path,
      requests.first.url.path,
      reason: '补读用的是同一个地址，只是换了个媒体类型',
    );
    expect(requests.last.url.queryParameters['ref'], 'main');
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
    expect(requests, hasLength(1), reason: '小文件不该多走一次 raw');
  });

  test('raw 那条路也被拒（403）：单列一条"太大"，不混成"读不出数据"', () async {
    final gateway = HttpGitHubBackupGateway(
      client: MockClient((request) async {
        if (request.headers['Accept'] == 'application/vnd.github.raw') {
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
}
