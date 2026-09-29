import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/models/github_backup_config.dart';
import '../core/store/github_sync.dart';

/// 调 GitHub 失败（网络、权限、地址、文件太大……）。
///
/// 与 `AiRequestException` 同一个形状：消息本身就是可以显示给用户的中文，
/// 界面不必再翻译一遍。
class GitHubBackupException implements Exception {
  const GitHubBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 「手机 ↔ GitHub」那一侧的抽象。
///
/// 留这个口子的原因与 AI 那一侧一样具体：`http` 在纯 Dart 测试里发不出真请求，
/// 而"两边都改过时不许自动覆盖""远程 0 条不算可用备份"这些**恰恰只有在
/// 特定响应下才验得出来**。
abstract interface class GitHubBackupGateway {
  /// 读远程那一份；文件不存在返回 `null`（**不是错误** —— 第一次推送就是这个状态）。
  Future<RemoteBackup?> readBackup({
    required GitHubBackupConfig config,
    required String token,
  });

  /// 覆盖写远程那一份（远程不存在时创建）。
  ///
  /// [knownSha] 是刚读到的 sha（`null` = 远程确实没有这份文件）；
  /// 带上它，GitHub 会在"读之后被别人改过"时返回 409 而不是悄悄覆盖。
  Future<RemoteBackup> writeBackup({
    required GitHubBackupConfig config,
    required String token,
    required List<int> bytes,
    required String message,
    required String? knownSha,
  });
}

/// 走 GitHub **Contents API** 的实现。
///
/// 只用这一套 API 是刻意的：它把"读一份文件"和"带提交信息覆盖一份文件"
/// 压成两个请求，用户不需要理解 git、也不会在我们这边多存一份状态。
/// 每次覆盖都是一次正常提交 —— 仓库自带的历史就是他额外的退路。
class HttpGitHubBackupGateway implements GitHubBackupGateway {
  const HttpGitHubBackupGateway();

  static const Duration timeout = Duration(seconds: 30);

  static const String _host = 'https://api.github.com';

  /// GitHub 要求带上 User-Agent，缺了会直接 403。
  static const String _userAgent = 'GuideLine-Android';

  @override
  Future<RemoteBackup?> readBackup({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) throw GitHubBackupException(reason);

    final uri = _contentsUri(cleaned, withRef: true);
    final response = await _send(() => http.get(uri, headers: _headers(token)));

    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) _throwFor(response, uri);

    final body = _decodedObject(response, uri);
    final sha = body['sha'];
    final content = body['content'];
    if (sha is! String || content is! String) {
      throw GitHubBackupException(
        '远程文件的格式不对（${uri.toString()}）：没读到 sha 或 content',
      );
    }

    late final List<int> bytes;
    try {
      bytes = base64.decode(content.replaceAll(RegExp(r'\s'), ''));
    } catch (error) {
      throw GitHubBackupException('远程文件的内容解不开（$error）');
    }

    return RemoteBackup.fromBytes(path: cleaned.path, sha: sha, bytes: bytes);
  }

  @override
  Future<RemoteBackup> writeBackup({
    required GitHubBackupConfig config,
    required String token,
    required List<int> bytes,
    required String message,
    required String? knownSha,
  }) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) throw GitHubBackupException(reason);

    final uri = _contentsUri(cleaned, withRef: false);
    final payload = <String, dynamic>{
      'message': message,
      'content': base64.encode(bytes),
      'branch': cleaned.branch,
      // 只有"远程已经有这份文件"时才带 sha；第一次推送时带 null 会被拒。
      'sha': ?knownSha,
    };

    final response = await _send(
      () => http.put(
        uri,
        headers: _headers(token, json: true),
        body: jsonEncode(payload),
      ),
    );

    if (response.statusCode >= 400) _throwFor(response, uri);

    final body = _decodedObject(response, uri);
    // PUT 的返回是 `{"content": {...}, "commit": {...}}`，新 sha 在 content 里。
    final content = body['content'];
    final sha = content is Map ? content['sha'] : null;
    if (sha is! String) {
      // 写成功了但没读到 sha 不该算失败：文件已经上去了。
      // 记账退化成"下次再读一次"，比把一个成功的写入报成失败安全得多。
      return RemoteBackup.fromBytes(path: cleaned.path, sha: '', bytes: bytes);
    }

    return RemoteBackup.fromBytes(path: cleaned.path, sha: sha, bytes: bytes);
  }

  Map<String, String> _headers(String token, {bool json = false}) =>
      <String, String>{
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': _userAgent,
        if (json) 'Content-Type': 'application/json',
      };

  Uri _contentsUri(GitHubBackupConfig config, {required bool withRef}) => Uri.parse(
        '$_host${config.contentsApiPath}'
        '${withRef ? '?ref=${Uri.encodeComponent(config.branch)}' : ''}',
      );

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(timeout);
    } on SocketException catch (error) {
      // 权限缺失在 Dart 侧也表现为 SocketException（与 AI 那一侧同一个坑：
      // debug 清单有联网权限、release 没有），所以文案里要把这条说出来。
      throw GitHubBackupException(
        '连不上 api.github.com（${error.osError?.message ?? error.message}）\n'
        '检查网络与该地址是否可达；若怎么都连不上，确认安装包的联网权限没有被去掉',
      );
    } on HttpException {
      throw const GitHubBackupException('网络请求失败，稍后再试');
    } on TimeoutException {
      throw const GitHubBackupException('请求超时（30 秒），稍后再试');
    } catch (error) {
      throw GitHubBackupException('请求超时或中断（$error）');
    }
  }

  Map<String, dynamic> _decodedObject(http.Response response, Uri uri) {
    final Object? root;
    try {
      root = jsonDecode(response.body);
    } catch (error) {
      throw GitHubBackupException(
        'GitHub 返回的不是 JSON（${uri.toString()}）：${_brief(response.body)}',
      );
    }
    if (root is! Map) {
      throw GitHubBackupException('GitHub 返回的不是对象（${uri.toString()}）');
    }
    return Map<String, dynamic>.from(root);
  }

  Never _throwFor(http.Response response, Uri uri) {
    switch (response.statusCode) {
      case 401:
        throw const GitHubBackupException(
          'Token 无效或已过期，重新生成一个再填进来',
        );
      case 403:
        throw const GitHubBackupException(
          '没有权限，或者被限流了：确认这个 Token 勾了 repo 权限、且对目标仓库有写权限',
        );
      case 404:
        throw GitHubBackupException(
          '仓库或分支不存在（404）：${uri.toString()}\n'
          '核对所有者、仓库名、分支名是否正确 —— 私有仓库用错 Token 也会显示 404',
        );
      case 409:
        throw const GitHubBackupException(
          '远程刚刚被改过，这次没有覆盖它：重新点一次，看清楚两边再决定',
        );
      case 413:
        throw const GitHubBackupException(
          '文件超过 GitHub 单个文件的 100 MB 上限，推不上去',
        );
      case 422:
        throw GitHubBackupException(
          'GitHub 拒绝了这次提交：${_brief(response.body)}',
        );
    }
    if (response.statusCode >= 500) {
      throw const GitHubBackupException('GitHub 那边出错了（5xx），过一会儿再试');
    }
    throw GitHubBackupException(
      'GitHub 返回 ${response.statusCode}：${_brief(response.body)}',
    );
  }

  /// 把响应体压成一句话（去掉 HTML 标签、压空白、截断）。
  static String _brief(String body) {
    final stripped = body
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (stripped.isEmpty) return '（空响应）';
    return stripped.length <= 160 ? stripped : '${stripped.substring(0, 160)}…';
  }
}

/// GitHub Token 的存取。
///
/// 与 `AiCredentialStore` 刻意**分成两个接口**：两者能活多久完全不同 ——
/// API Key 泄露只损失额度，一个带 repo 权限的 Token 泄露等于把仓库交出去，
/// 将来要单独加"打开应用要指纹"之类的限制时，改这里不会牵动 AI 那一侧。
///
/// "Token 只进安全存储"这一条是 ADR-088 与 §10.2 一起钉住的硬约束：
/// 偏好 JSON 里连键都不出现，整库导出与滚动备份天然不含它。
abstract interface class GitHubCredentialStore {
  Future<String?> readToken();

  Future<void> writeToken(String value);

  Future<void> clearToken();
}

/// 存进系统安全存储（Android Keystore）的实现。
class SecureGitHubCredentialStore implements GitHubCredentialStore {
  const SecureGitHubCredentialStore();

  static const String _key = 'guideline.github.token';

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
      // 部分 ROM 上 Keystore 会偶发失败；读不出来一律当"没配置"，
      // 不抛错、不崩界面（与 AI 那一条同一口径）。
      return null;
    }
  }

  @override
  Future<void> writeToken(String value) =>
      _storage.write(key: _key, value: value.trim());

  @override
  Future<void> clearToken() => _storage.delete(key: _key);
}
