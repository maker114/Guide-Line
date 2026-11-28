import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/models/server_backup_config.dart';
import '../core/store/github_sync.dart';
import '../core/store/sha256.dart';

/// 调自建同步服务器失败（网络、鉴权、版本冲突、太大……）。
///
/// 消息本身就是可以显示给用户的中文；[network] 只标"连不上 / 超时"，
/// 与 GitHub 那一侧的 `GitHubBackupException` 同一条口径：
/// 指纹不对、Token 不对都不是网络问题，不该被当成"稍后再试"。
class ServerBackupException implements Exception {
  const ServerBackupException(this.message, {this.network = false});

  final String message;

  /// true = 连不上 / 超时；false = 证书、Token、版本、体积这类。
  final bool network;

  @override
  String toString() => message;
}

/// 旧服务端还没有 `GET /v1/backup/watch`（长轮询）时抛这个。
///
/// 它不是错误，而是一条**能力探测结果**：调用方收到它就降级成定时轮询，
/// 不该把它显示成"同步失败"。
class ServerWatchUnsupported implements Exception {
  const ServerWatchUnsupported();
}

/// 服务器上那一份备份的元信息（不含内容）。
class ServerMeta {
  const ServerMeta({
    required this.revision,
    required this.sha256,
    required this.size,
    required this.savedAt,
    required this.recordCount,
    this.appVersion = '',
    this.updatedAt = 0,
  });

  /// 单调递增的上传编号：**每推一次 +1**，是服务端判定"这一份是不是同一次上传"的凭证。
  final int revision;

  /// 内容的 SHA-256（小写十六进制）——答"内容一不一样"。
  final String sha256;

  final int size;

  /// 上传时客户端给的 `exportedAt`（毫秒），用来和本地 `savedAt` 比新旧。
  final int savedAt;

  /// 客户端上报的活记录条数（只用于显示，服务端不校验）。
  final int recordCount;

  /// 上传时客户端报的版本号（`2.11.0+103`），排查用。
  final String appVersion;

  /// 服务器写盘时刻（毫秒）。
  final int updatedAt;
}

/// 「客户端 ↔ 自建服务器」那一侧的抽象。
///
/// 与 GitHub 的 `GitHubBackupGateway` 分开定义，是因为两边对"同一份"的凭证不同：
/// GitHub 用提交码，这里用**上传编号**（[ServerMeta.revision]）。共用的部分
/// （`RemoteBackup` 的解析、`analyzeSync` 的判定）仍走 `core/store/github_sync.dart`，
/// 不另写一套冲突逻辑。
abstract interface class ServerBackupGateway {
  /// 读远程那一份；没有返回 `null`（第一次推送就是这个状态）。
  Future<RemoteBackup?> readBackup({
    required ServerBackupConfig config,
    required String token,
  });

  /// 读元信息（不下载内容）；没有返回 `null`。
  Future<ServerMeta?> readMeta({
    required ServerBackupConfig config,
    required String token,
  });

  /// 长轮询：等到上传编号大于 [since]，或 [timeout] 到期。
  ///
  /// 返回 `null` = 这段时间服务器上没有新版本（不是错误）。
  /// 旧服务端没有这个接口时抛 [ServerWatchUnsupported]，调用方降级成定时轮询。
  Future<ServerMeta?> watchMeta({
    required ServerBackupConfig config,
    required String token,
    required int since,
    Duration timeout = const Duration(seconds: 25),
  });

  /// 覆盖写远程那一份。
  ///
  /// [baseRevision] 是**刚读到的**上传编号（0 = 远程还没有），带它上去，
  /// 服务端在"读之后被别人改过"时回 409，而不是悄悄覆盖。
  /// 返回值里的 [RemoteBackup.commitSha] 是这次的上传编号。
  Future<RemoteBackup> writeBackup({
    required ServerBackupConfig config,
    required String token,
    required List<int> bytes,
    required int baseRevision,
    required int savedAt,
    required int recordCount,
    String appVersion = '',
  });

  /// 问一句"服务在不在"（不需要 Token）。
  Future<void> ping({required ServerBackupConfig config});
}

/// 走自建 HTTPS 服务的实现。
///
/// **证书固定**：服务端用自签证书，客户端不靠系统信任链，而是把部署时读出的
/// SHA-256 指纹填进配置，由 [HttpClient.badCertificateCallback] 逐张比对。
/// 指纹没填 / 对不上一律拒绝 —— 这比"信任所有证书"强，也比要求用户去装 CA 简单。
class HttpServerBackupGateway implements ServerBackupGateway {
  HttpServerBackupGateway({
    http.Client Function(ServerBackupConfig config)? clientFactory,
  }) : _clientFactory = clientFactory ?? _pinnedClient;

  /// 测试注入点：单测里用 `MockClient` 代替真实 socket（真 TLS 在部署后验证）。
  final http.Client Function(ServerBackupConfig config) _clientFactory;

  static const Duration timeout = Duration(seconds: 30);

  @override
  Future<RemoteBackup?> readBackup({
    required ServerBackupConfig config,
    required String token,
  }) async {
    final cleaned = _checked(config);
    final response = await _send(
      cleaned,
      token,
      (client) => client.get(_uri(cleaned, '/v1/backup'), headers: _headers(token)),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) _throwFor(response);

    final bytes = response.bodyBytes;
    final revision = response.headers['x-backup-revision'] ?? '';
    final sha = response.headers['x-backup-sha256'] ??
        (bytes.isEmpty ? '' : sha256Hex(bytes));
    return RemoteBackup.fromBytes(
      path: '/v1/backup',
      sha: sha,
      bytes: bytes,
      commitSha: revision,
    );
  }

  @override
  Future<ServerMeta?> readMeta({
    required ServerBackupConfig config,
    required String token,
  }) async {
    final cleaned = _checked(config);
    final response = await _send(
      cleaned,
      token,
      (client) => client.get(
        _uri(cleaned, '/v1/backup/meta'),
        headers: _headers(token),
      ),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) _throwFor(response);
    return _metaFrom(_decodedObject(response));
  }

  @override
  Future<ServerMeta?> watchMeta({
    required ServerBackupConfig config,
    required String token,
    required int since,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final cleaned = _checked(config);
    if (since < 0) {
      throw const ServerBackupException('上传编号不能为负');
    }
    final seconds = timeout.inSeconds.clamp(1, 50);
    final response = await _send(
      cleaned,
      token,
      (client) => client.get(
        _uri(cleaned, '/v1/backup/watch?since=$since&timeout=$seconds'),
        headers: _headers(token),
      ),
      // 服务端最多挂 50 秒；客户端留出余量，别把"等得久"当成"网络不好"。
      requestTimeout: Duration(seconds: seconds + 15),
    );
    // 204 = 这段时间没有新版本（长轮询正常到期）。
    if (response.statusCode == 204) return null;
    if (response.statusCode == 404) {
      final body = _tryDecodeObject(response);
      // 旧服务端没有这个路由：这是能力探测结果，不是同步失败。
      if (body == null || body['error'] == 'not_found') {
        throw const ServerWatchUnsupported();
      }
      // "还没有备份"不算新版本。
      return null;
    }
    if (response.statusCode >= 400) _throwFor(response);
    return _metaFrom(_decodedObject(response));
  }

  @override
  Future<RemoteBackup> writeBackup({
    required ServerBackupConfig config,
    required String token,
    required List<int> bytes,
    required int baseRevision,
    required int savedAt,
    required int recordCount,
    String appVersion = '',
  }) async {
    final cleaned = _checked(config);
    final response = await _send(
      cleaned,
      token,
      (client) => client.put(
        _uri(cleaned, '/v1/backup'),
        headers: <String, String>{
          ..._headers(token),
          'Content-Type': 'application/gzip',
          'X-Base-Revision': '$baseRevision',
          'X-Backup-Saved-At': '$savedAt',
          'X-Record-Count': '$recordCount',
          'X-App-Version': appVersion,
        },
        body: bytes,
      ),
    );
    if (response.statusCode >= 400) _throwFor(response);

    final meta = _metaFrom(_decodedObject(response));
    return RemoteBackup.fromBytes(
      path: '/v1/backup',
      sha: meta.sha256,
      bytes: bytes,
      commitSha: '${meta.revision}',
    );
  }

  @override
  Future<void> ping({required ServerBackupConfig config}) async {
    final cleaned = _checked(config);
    final response = await _send(
      cleaned,
      '',
      (client) => client.get(_uri(cleaned, '/healthz')),
      auth: false,
    );
    if (response.statusCode >= 400) _throwFor(response);
    final body = _decodedObject(response);
    if (body['ok'] != true) {
      throw const ServerBackupException('服务器回了话，但不是 GuideLine 同步服务');
    }
  }

  ServerBackupConfig _checked(ServerBackupConfig config) {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) throw ServerBackupException(reason);
    return cleaned;
  }

  Uri _uri(ServerBackupConfig config, String path) =>
      Uri.parse('${config.baseUrl}$path');

  Map<String, String> _headers(String token) => <String, String>{
        'Accept': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  Future<http.Response> _send(
    ServerBackupConfig config,
    String token,
    Future<http.Response> Function(http.Client client) request, {
    bool auth = true,
    Duration? requestTimeout,
  }) async {
    if (auth && token.trim().isEmpty) {
      throw const ServerBackupException('还没填服务器 Token');
    }
    final effectiveTimeout = requestTimeout ?? timeout;
    final client = _clientFactory(config);
    try {
      return await request(client).timeout(effectiveTimeout);
    } on SocketException catch (error) {
      throw ServerBackupException(
        '连不上 ${config.displayHost}：${error.osError?.message ?? error.message}\n'
        '请检查地址、端口与网络；服务器换了 IP 或证书也要重新核对。',
        network: true,
      );
    } on TimeoutException {
      throw ServerBackupException(
        '请求超过 ${effectiveTimeout.inSeconds} 秒未完成，请稍后再试',
        network: true,
      );
    } on HandshakeException {
      // 自签证书 + 指纹固定：对不上时握手在到达 HTTP 层之前就失败了，
      // 不接住会漏出英文的 `CERTIFICATE_VERIFY_FAILED`。
      throw const ServerBackupException(
        'TLS 握手失败：服务器证书与填进来的指纹对不上。\n'
        '请到服务器上重新读一次证书指纹，或确认地址没有被别的服务顶替。',
      );
    } on http.ClientException catch (error) {
      throw ServerBackupException(_clientFailure(error.message), network: true);
    } finally {
      client.close();
    }
  }

  /// 把 `http` 包在 TLS 失败外面那句英文翻成人能看懂的一句话。
  ///
  /// 自签证书对不上时 Dart 抛的是 `HandshakeException`，`http` 会把它包成
  /// `ClientException` —— 而用户看到 "HandshakeException: ..." 只会去检查网络，
  /// 真正该做的是回同步页核对指纹。
  static String _clientFailure(String message) {
    final lower = message.toLowerCase();
    if (lower.contains('certificate') || lower.contains('handshake')) {
      return 'TLS 握手失败：服务器证书与填进来的指纹对不上。\n'
          '请到服务器上重新读一次证书指纹，或确认地址没有被别的服务顶替。';
    }
    return '网络请求失败：$message';
  }

  Map<String, dynamic> _decodedObject(http.Response response) {
    final Object? root;
    try {
      root = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw ServerBackupException(
        '服务器返回的不是 JSON（HTTP ${response.statusCode}）',
      );
    }
    if (root is! Map) {
      throw ServerBackupException('服务器返回的不是 JSON 对象（HTTP ${response.statusCode}）');
    }
    return Map<String, dynamic>.from(root);
  }

  Map<String, dynamic>? _tryDecodeObject(http.Response response) {
    try {
      final root = jsonDecode(utf8.decode(response.bodyBytes));
      if (root is Map) return Map<String, dynamic>.from(root);
    } catch (_) {
      // 404 的正文不是 JSON 也不影响判断（下面按"旧服务端"处理）。
    }
    return null;
  }

  ServerMeta _metaFrom(Map<String, dynamic> body) {
    final revision = body['revision'];
    final sha = body['sha256'];
    if (revision is! int || sha is! String) {
      throw const ServerBackupException('服务器返回的元信息缺字段：revision / sha256');
    }
    return ServerMeta(
      revision: revision,
      sha256: sha,
      size: body['size'] is int ? body['size'] as int : 0,
      savedAt: body['savedAt'] is int ? body['savedAt'] as int : 0,
      recordCount: body['recordCount'] is int ? body['recordCount'] as int : 0,
      appVersion: body['appVersion'] is String ? body['appVersion'] as String : '',
      updatedAt: body['updatedAt'] is int ? body['updatedAt'] as int : 0,
    );
  }

  Never _throwFor(http.Response response) {
    switch (response.statusCode) {
      case 401:
        throw const ServerBackupException('Token 不对或已失效：请回服务器上核对 Token');
      case 403:
        throw const ServerBackupException('服务器拒绝了这次请求（HTTP 403）');
      case 409:
        throw const ServerBackupException(
          '远程刚被别的设备改过，这次没有覆盖它：重新点一次，看清楚两边再决定',
        );
      case 413:
        throw const ServerBackupException('这份备份超过服务器允许的大小上限，推不上去');
      case 400:
        throw const ServerBackupException('服务器说这份请求不合法（HTTP 400）');
    }
    if (response.statusCode >= 500) {
      throw const ServerBackupException('服务器出错了（HTTP 5xx），请稍后再试');
    }
    throw ServerBackupException('服务器返回 HTTP ${response.statusCode}');
  }

  /// 默认的客户端：固定证书指纹。
  static http.Client _pinnedClient(ServerBackupConfig config) {
    final io = HttpClient();
    io.connectionTimeout = timeout;
    io.badCertificateCallback = (X509Certificate cert, String host, int port) =>
        acceptServerCertificate(der: cert.der, host: host, config: config);
    return IOClient(io);
  }
}

/// 证书固定的判据：**主机对得上、指纹也对得上**才放行。
///
/// 单独写成顶层函数是为了能被纯 Dart 测到（不启真 socket、不碰平台层）：
/// 自签证书只靠这一条判断，写错一个方向就会变成"任意证书都放行"。
bool acceptServerCertificate({
  required List<int> der,
  required String host,
  required ServerBackupConfig config,
}) {
  if (host != config.host) return false;
  return sha256Hex(der) == config.normalized().fingerprint;
}

/// 服务器 Token 的存取（与 AI 的 `apiKey`、GitHub 的 `token` 分开存）。
abstract interface class ServerCredentialStore {
  Future<String?> readToken();

  Future<void> writeToken(String value);

  Future<void> clearToken();
}

/// 存进系统安全存储（Android Keystore / 桌面凭据库）的实现。
class SecureServerCredentialStore implements ServerCredentialStore {
  const SecureServerCredentialStore();

  static const String _key = 'guideline.server.token';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  @override
  Future<String?> readToken() async {
    try {
      final value = await _storage.read(key: _key);
      if (value == null) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeToken(String value) =>
      _storage.write(key: _key, value: value.trim());

  @override
  Future<void> clearToken() => _storage.delete(key: _key);
}
