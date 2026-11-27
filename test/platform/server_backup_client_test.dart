import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/models/server_backup_config.dart';
import 'package:guideline/core/store/sha256.dart';
import 'package:guideline/platform/server_backup_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 服务器网关的**报文层**：读 / 写 / 元信息 / 错误码。
///
/// 这里用 `MockClient` 替换 socket —— 真 TLS 与证书固定要部署后验（那是另一条
/// 验证路径），而"409 不能当成成功""401 要说 Token 不对"这些判定必须在这里钉住。
void main() {
  const pin =
      '3f786850e387550fdab836ed7e6dc881de23001b8ee5a7d4a32a7f0f7a8f3c7f';
  const config = ServerBackupConfig(
    enabled: true,
    baseUrl: 'https://sync.example:8443',
    fingerprint: pin,
  );
  const token = 'test-token';

  ServerBackupGateway gatewayWith(
    Future<http.Response> Function(http.Request request) handler,
  ) =>
      HttpServerBackupGateway(clientFactory: (_) => MockClient(handler));

  test('读回整份：sha 与上传编号来自响应头', () async {
    final gateway = gatewayWith((request) async {
      expect(request.url.path, '/v1/backup');
      expect(request.headers['Authorization'], 'Bearer $token');
      return http.Response.bytes(
        utf8.encode('gz-bytes'),
        200,
        headers: <String, String>{
          'x-backup-revision': '7',
          'x-backup-sha256': 'a' * 64,
          'x-backup-saved-at': '1700000000000',
          'x-record-count': '42',
        },
      );
    });

    final remote = await gateway.readBackup(config: config, token: token);
    expect(remote, isNotNull);
    expect(remote!.commitSha, '7');
    expect(remote.sha, 'a' * 64);
    expect(toStringDecoded(remote.bytes), 'gz-bytes');
  });

  test('服务器上还没有备份时读回 null（不是错误）', () async {
    final gateway = gatewayWith((_) async => http.Response('{"error":"empty"}', 404));
    expect(await gateway.readBackup(config: config, token: token), isNull);
    expect(await gateway.readMeta(config: config, token: token), isNull);
  });

  test('401 说 Token 不对', () async {
    final gateway = gatewayWith((_) async => http.Response('{"error":"unauthorized"}', 401));
    await expectLater(
      gateway.readBackup(config: config, token: token),
      throwsA(
        isA<ServerBackupException>().having((e) => e.message, 'message', contains('Token')),
      ),
    );
  });

  test('写入带上基线版本，返回新的上传编号', () async {
    late http.Request seen;
    final gateway = gatewayWith((request) async {
      seen = request;
      return http.Response(
        jsonEncode(<String, Object>{
          'revision': 4,
          'sha256': 'b' * 64,
          'size': 8,
          'savedAt': 1700000000000,
          'recordCount': 12,
          'appVersion': '2.11.0+103',
          'updatedAt': 1700000000001,
        }),
        201,
      );
    });

    final written = await gateway.writeBackup(
      config: config,
      token: token,
      bytes: <int>[1, 2, 3],
      baseRevision: 3,
      savedAt: 1700000000000,
      recordCount: 12,
      appVersion: '2.11.0+103',
    );

    expect(written.commitSha, '4');
    expect(written.sha, 'b' * 64);
    expect(seen.method, 'PUT');
    expect(seen.headers['X-Base-Revision'], '3');
    expect(seen.headers['X-Record-Count'], '12');
  });

  test('409 说明远程被改过，不能当成成功', () async {
    final gateway = gatewayWith(
      (_) async => http.Response('{"error":"version_conflict"}', 409),
    );
    await expectLater(
      gateway.writeBackup(
        config: config,
        token: token,
        bytes: <int>[1],
        baseRevision: 1,
        savedAt: 1,
        recordCount: 1,
      ),
      throwsA(
        isA<ServerBackupException>().having(
          (e) => e.message,
          'message',
          contains('刚被'),
        ),
      ),
    );
  });

  test('元信息解析', () async {
    final gateway = gatewayWith(
      (_) async => http.Response(
        jsonEncode(<String, Object>{
          'revision': 9,
          'sha256': 'c' * 64,
          'size': 1024,
          'savedAt': 1700000000000,
          'recordCount': 5,
          'appVersion': '2.11.0+103',
          'updatedAt': 1700000000001,
        }),
        200,
      ),
    );
    final meta = await gateway.readMeta(config: config, token: token);
    expect(meta!.revision, 9);
    expect(meta.recordCount, 5);
    expect(meta.sha256, 'c' * 64);
  });

  test('配置不全时连请求都不发', () async {
    var called = false;
    final gateway = gatewayWith((_) async {
      called = true;
      return http.Response('{}', 200);
    });
    await expectLater(
      gateway.readBackup(
        config: const ServerBackupConfig(baseUrl: 'http://x'),
        token: token,
      ),
      throwsA(isA<ServerBackupException>()),
    );
    expect(called, isFalse);
  });

  test('证书固定：主机与指纹两样都对得上才放行', () {
    final der = <int>[1, 2, 3, 4, 5, 6, 7];
    final config = ServerBackupConfig(
      baseUrl: 'https://sync.example:8443',
      fingerprint: sha256Hex(der),
    );
    expect(
      acceptServerCertificate(der: der, host: 'sync.example', config: config),
      isTrue,
    );
    expect(
      acceptServerCertificate(der: der, host: 'other.example', config: config),
      isFalse,
    );
    expect(
      acceptServerCertificate(der: <int>[9, 9], host: 'sync.example', config: config),
      isFalse,
    );
  });
}

String toStringDecoded(List<int> bytes) => utf8.decode(bytes);
