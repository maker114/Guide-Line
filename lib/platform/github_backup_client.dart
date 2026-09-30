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
  /// 返回值的 [RemoteBackup.commitSha] 是**这一次提交的提交码**。
  Future<RemoteBackup> writeBackup({
    required GitHubBackupConfig config,
    required String token,
    required List<int> bytes,
    required String message,
    required String? knownSha,
  });

  /// 读远程**此刻**那一次提交（只取提交列表的第一条，ADR-089）。
  ///
  /// 与 [readBackup] 问的不是同一件事：那一份是"文件内容里有什么"，
  /// 这一条是"这份文件最后是被哪一次提交改的"。双端对版本要的是后者 ——
  /// 提交码相同才说明"我们说的是同一次上传"。
  ///
  /// 仓库里还没有任何提交（GitHub 对空仓库返回 409）或这个路径还没提交过
  /// 时返回 `null`：那是**还没有**，不是错误。
  Future<RemoteCommit?> latestCommit({
    required GitHubBackupConfig config,
    required String token,
  });

  /// 问仓库本身在不在、这个 Token 看不看得见它（ADR-090）。
  ///
  /// 与 [readBackup] 的区别就是 `404` 的两种意思：Contents API 对
  /// "仓库 / 权限不对"和"仓库在、只是这份文件还没推过"回的是同一个 404，
  /// 只看它就会把 owner 拼错报成「连通成功，远程还没有备份」。
  ///
  /// 仓库不存在（或这个 Token 看不到它，GitHub 对私有仓库一律回 404）
  /// 时抛 [GitHubBackupException]，消息本身就是给用户看的那一句。
  Future<RemoteRepository> describeRepository({
    required GitHubBackupConfig config,
    required String token,
  });
}

/// 走 GitHub **Contents API** 的实现。
///
/// 只用这一套 API 是刻意的：它把"读一份文件"和"带提交信息覆盖一份文件"
/// 压成两个请求，用户不需要理解 git、也不会在我们这边多存一份状态。
/// 每次覆盖都是一次正常提交 —— 仓库自带的历史就是他额外的退路。
///
/// [client] 只在测试里传：`http` 在纯 Dart 测试里发不出真请求，而"文件超过
/// 1 MB 时 GitHub 只回空 content""仓库不存在与文件不存在都是 404"这两条
/// **恰恰只有在特定响应下才验得出来** —— 与本文件顶部那个接口同一个理由。
class HttpGitHubBackupGateway implements GitHubBackupGateway {
  HttpGitHubBackupGateway({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration timeout = Duration(seconds: 30);

  /// 读大文件时的超时上限：**按体积放宽**，不跟 [timeout] 共用一条线。
  ///
  /// 这条线是实测出来的，不是拍的：1.38 MB 的备份在一条慢链路上
  /// 读回来要 68 秒（约 28 KB/s），30 秒的固定超时会把"正在读"掐成
  /// 「请求超时」—— 那和 PL-9 修之前的"静默 0 条"一样，用户拿不到备份，
  /// 只是这回至少有句话。按 10 KB/s 打底、5 分钟封顶，慢网也读得完。
  static const Duration maxReadTimeout = Duration(minutes: 5);

  /// 每读 10 KB 给一秒。
  static const int _readBytesPerSecond = 10 * 1024;

  /// 按体积算读这份文件的超时：小文件仍是 [timeout]，大文件按
  /// [_readBytesPerSecond] 放宽，不超过 [maxReadTimeout]。
  static Duration readBudgetFor(int? byteCount) {
    if (byteCount == null || byteCount <= 0) return timeout;
    final seconds = (byteCount / _readBytesPerSecond).ceil();
    return Duration(
      seconds: seconds.clamp(timeout.inSeconds, maxReadTimeout.inSeconds),
    );
  }

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
    final response = await _send(() => _client.get(uri, headers: _headers(token)));

    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) _throwFor(response, uri);

    final body = _decodedObject(response, uri);
    final sha = body['sha'];
    final content = body['content'];
    // 元数据里带着文件体积：读大文件时靠它算超时（见 [readBudgetFor]）。
    final size = body['size'];
    if (sha is! String) {
      throw GitHubBackupException(
        '远程文件的格式不对：${uri.toString()}，没有读到 sha',
      );
    }

    final List<int> bytes;
    if (content is String && content.isNotEmpty) {
      try {
        bytes = base64.decode(content.replaceAll(RegExp(r'\s'), ''));
      } catch (error) {
        throw GitHubBackupException('远程文件的内容解不开：$error');
      }
    } else {
      // 1 MB 以上的文件，默认的 object 媒体类型只回一个**空 content**
      // （`encoding` 写着 `none`），而 `base64.decode('')` 不抛错 ——
      // 旧写法于是把"文件太大"读成"这份备份读不出数据"：拉取永远失败，
      // 推送却照常能用，界面上看不出任何原因（ADR-090）。
      bytes = await _readBlobBytes(
        cleaned,
        token,
        sha,
        knownSize: size is int ? size : null,
      );
    }

    return RemoteBackup.fromBytes(path: cleaned.path, sha: sha, bytes: bytes);
  }

  /// 大文件走 **Git Blobs API** 把内容读回来（1–100 MB 只有这一条路）。
  ///
  /// 为什么不直接用 `/contents` 配 `Accept: application/vnd.github.raw`：
  /// 那条路实测**读不完** —— 1.38 MB 的备份传到 33 秒被掐断
  /// （`ClientException: Connection closed while receiving data`），而改走
  /// `git/blobs/{sha}`，同一个主机、同样带 Token 的普通 JSON 请求，
  /// 1,875,799 字节 base64 一字不少地传完（实测 68 秒）。代价是 base64 让
  /// 体积涨三分之一，换来的是"真能读回来"—— 这一条比省流量重要。
  ///
  /// [knownSize] 是元数据里的体积，用来按体积放宽超时：1.38 MB 实测要 68 秒，
  /// 30 秒那条线会把"正在读"掐成「请求超时」（见 [readBudgetFor]）。
  Future<List<int>> _readBlobBytes(
    GitHubBackupConfig config,
    String token,
    String sha, {
    int? knownSize,
  }) async {
    final uri = Uri.parse('$_host${config.blobApiPath(sha)}');
    final response = await _send(
      () => _client.get(uri, headers: _headers(token)),
      budget: readBudgetFor(knownSize),
    );

    if (response.statusCode == 403 || response.statusCode == 413) {
      // 单文件读取上限（100 MB）：这也是推送的极限。单列一条可读文案，
      // 不把它混进"这份备份读不出数据"里 —— 那会让人以为是文件坏了。
      throw const GitHubBackupException(
        '远程备份过大，超过 GitHub 单文件 100 MB 上限，无法通过接口读回。\n'
        '请到仓库网页手动下载，或减小备份体积后重试',
      );
    }
    if (response.statusCode >= 400) _throwFor(response, uri);

    final body = _decodedObject(response, uri);
    final content = body['content'];
    final encoding = body['encoding'];
    if (content is! String || content.isEmpty) {
      throw GitHubBackupException(
        '远程备份读回的内容为空，encoding 为 ${encoding ?? '未知'}：'
        '文件可能刚被清空，也可能 GitHub 只返回了元数据。\n'
        '请重试一次；若仍然为空，请到仓库网页查看这个文件',
      );
    }
    // blob 的 `content` 默认是 base64；纯文本文件才回 `utf-8`。
    if (encoding == 'utf-8') return utf8.encode(content);
    try {
      return base64.decode(content.replaceAll(RegExp(r'\s'), ''));
    } catch (error) {
      throw GitHubBackupException('远程文件的内容解不开：$error');
    }
  }

  @override
  Future<RemoteRepository> describeRepository({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) throw GitHubBackupException(reason);

    final uri = Uri.parse('$_host${cleaned.repositoryApiPath}');
    final response = await _send(() => _client.get(uri, headers: _headers(token)));

    // 404 就按 [_throwFor] 里那一句报出去（"仓库或分支不存在"）——
    // 那正是这个请求存在的意义：把仓库/权限不对与"文件还没推过"分开。
    if (response.statusCode >= 400) _throwFor(response, uri);

    final body = _decodedObject(response, uri);
    final fullName = body['full_name'];
    final defaultBranch = body['default_branch'];
    return RemoteRepository(
      fullName: fullName is String && fullName.isNotEmpty
          ? fullName
          : '${cleaned.owner}/${cleaned.repo}',
      isPrivate: body['private'] == true,
      defaultBranch: defaultBranch is String ? defaultBranch : '',
    );
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
      () => _client.put(
        uri,
        headers: _headers(token, json: true),
        body: jsonEncode(payload),
      ),
    );

    if (response.statusCode >= 400) _throwFor(response, uri);

    final body = _decodedObject(response, uri);
    // PUT 的返回是 `{"content": {...}, "commit": {...}}`：
    // 文件的新内容码在 content 里，**这一次提交的提交码**在 commit 里。
    // 两个都要：内容码用来做下次覆盖的基线，提交码是给用户对版本的凭证。
    final content = body['content'];
    final commit = body['commit'];
    final sha = content is Map ? content['sha'] : null;
    final commitSha = commit is Map ? commit['sha'] : null;
    final commitText = commitSha is String ? commitSha : '';
    if (sha is! String) {
      // 写成功了但没读到 sha 不该算失败：文件已经上去了。
      // 记账退化成"下次再读一次"，比把一个成功的写入报成失败安全得多。
      return RemoteBackup.fromBytes(
        path: cleaned.path,
        sha: '',
        bytes: bytes,
        commitSha: commitText,
      );
    }

    return RemoteBackup.fromBytes(
      path: cleaned.path,
      sha: sha,
      bytes: bytes,
      commitSha: commitText,
    );
  }

  @override
  Future<RemoteCommit?> latestCommit({
    required GitHubBackupConfig config,
    required String token,
  }) async {
    final cleaned = config.normalized();
    final reason = cleaned.validate();
    if (reason != null) throw GitHubBackupException(reason);

    final uri = _commitsUri(cleaned);
    final response = await _send(() => _client.get(uri, headers: _headers(token)));

    // 409 = 空仓库（一条提交都还没有）；404 = 这个分支 / 仓库读不到。
    // 两种都回答"此刻读不到提交" —— 那是**还没有**，不是错误：
    // "仓库到底存不存在"是「测试连接」那一句要回答的事（另一轮修）。
    if (response.statusCode == 404 || response.statusCode == 409) return null;
    if (response.statusCode >= 400) _throwFor(response, uri);

    final Object? root;
    try {
      root = jsonDecode(response.body);
    } catch (error) {
      throw GitHubBackupException(
        'GitHub 返回的不是 JSON：${uri.toString()}，${_brief(response.body)}',
      );
    }
    if (root is! List || root.isEmpty) return null;

    final first = root.first;
    if (first is! Map) return null;
    final sha = first['sha'];
    if (sha is! String || sha.isEmpty) return null;

    final commit = first['commit'];
    final message = commit is Map ? commit['message'] : null;
    final committer = commit is Map ? commit['committer'] : null;
    final date = committer is Map ? committer['date'] : null;

    return RemoteCommit(
      sha: sha,
      // 提交说明只取首行：正文可能很长，界面上只摆得下一行。
      message: message is String ? message.split('\n').first.trim() : '',
      committedAt: date is String
          ? DateTime.tryParse(date)?.millisecondsSinceEpoch
          : null,
    );
  }

  Map<String, String> _headers(String token, {bool json = false}) =>
      <String, String>{
        'Authorization': 'Bearer $token',
        // 每一句都是普通的 JSON 请求：读大文件走 Git Blobs API，回来的也是
        // JSON（内容是 base64 字段），不再有"这一次回来的是文件本身"那种特例。
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': _userAgent,
        if (json) 'Content-Type': 'application/json',
      };

  Uri _contentsUri(GitHubBackupConfig config, {required bool withRef}) => Uri.parse(
        '$_host${config.contentsApiPath}'
        '${withRef ? '?ref=${Uri.encodeComponent(config.branch)}' : ''}',
      );

  /// 提交列表的地址：**只取一条**，问的就是"这个路径最后一次被谁改的"。
  ///
  /// `path` 与 `sha` 都带上：前者把范围收到我们那份文件上（不然第一条会
  /// 是别人对仓库里任何一个文件的提交），后者钉住分支（默认分支未必是它）。
  Uri _commitsUri(GitHubBackupConfig config) => Uri.parse(
        '$_host${config.commitsApiPath}'
        '?path=${Uri.encodeComponent(config.path)}'
        '&sha=${Uri.encodeComponent(config.branch)}'
        '&per_page=1',
      );

  /// [budget] 只在读大文件时传（见 [readBudgetFor]）：其余请求都用 [timeout]。
  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    Duration? budget,
  }) async {
    final limit = budget ?? timeout;
    try {
      return await request().timeout(limit);
    } on SocketException catch (error) {
      // 权限缺失在 Dart 侧也表现为 SocketException（与 AI 那一侧同一个坑：
      // debug 清单有联网权限、release 没有），所以文案里要把这条说出来。
      throw GitHubBackupException(
        '连不上 api.github.com：${error.osError?.message ?? error.message}\n'
        '请检查网络与该地址是否可达；若始终连不上，请确认安装包的联网权限没有被去掉',
      );
    } on HttpException {
      throw const GitHubBackupException('网络请求失败，稍后再试');
    } on TimeoutException {
      throw GitHubBackupException('请求超过 ${limit.inSeconds} 秒未完成，请稍后再试');
    } catch (error) {
      throw GitHubBackupException('请求超时或中断：$error');
    }
  }

  Map<String, dynamic> _decodedObject(http.Response response, Uri uri) {
    final Object? root;
    try {
      root = jsonDecode(response.body);
    } catch (error) {
      throw GitHubBackupException(
        'GitHub 返回的不是 JSON：${uri.toString()}，${_brief(response.body)}',
      );
    }
    if (root is! Map) {
      throw GitHubBackupException('GitHub 返回的不是对象：${uri.toString()}');
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
          '仓库或分支不存在，HTTP 404：${uri.toString()}\n'
          '请核对所有者、仓库名、分支名是否正确；私有仓库用错 Token 也会返回 404',
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
      throw const GitHubBackupException('GitHub 服务端出错，HTTP 5xx，请稍后再试');
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
    if (stripped.isEmpty) return '空响应';
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
