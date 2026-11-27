/// 「服务器同步」的**非敏感**配置（纯数据 + 纯校验）。
///
/// 与 `GitHubBackupConfig` 同一套路数：`token` 不在这个类里，只进系统安全存储；
/// 这里只有地址、证书指纹与开关。
///
/// 两条边界写死在 [validate] 里，界面与控制器都只看它：
///   · **只接受 `https://`** —— 这条管线会把整份人生记录发到自建服务器上，
///     明文 HTTP 等于把内容摊在链路上；
///   · **必须填证书指纹** —— 自签证书只靠系统信任链验不过去，客户端固定指纹
///     才挡得住"同一 IP 上的另一张证书"（见 `server_backup_client.dart`）。
class ServerBackupConfig {
  const ServerBackupConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.fingerprint = '',
  });

  /// 总开关（默认关）。关掉不清地址 / 指纹 / Token，也不删服务器上那份。
  final bool enabled;

  /// 形如 `https://120.55.11.161:8443`（不带路径）。
  final String baseUrl;

  /// 服务端证书的 SHA-256 指纹，64 位十六进制，允许冒号分组。
  ///
  /// 由部署时 `openssl x509 -fingerprint -sha256` 读出来，贴进这一格；
  /// 换了证书（例如公网 IP 变了重新签发）就必须重新贴一次。
  final String fingerprint;

  /// 去掉首尾空白与末尾斜杠；指纹统一成小写、去掉冒号与空格。
  ServerBackupConfig normalized() => ServerBackupConfig(
        enabled: enabled,
        baseUrl: _trimTrailingSlash(baseUrl.trim()),
        fingerprint: normalizeFingerprint(fingerprint),
      );

  /// 把指纹里的分隔符去掉、转小写（`AB:CD:…` 与 `abcd…` 视为同一个）。
  static String normalizeFingerprint(String value) =>
      value.replaceAll(RegExp(r'[:：\s-]'), '').toLowerCase();

  /// 返回**可以直接显示**的中文原因，`null` 表示配置齐全。
  String? validate() {
    final cleaned = normalized();

    if (cleaned.baseUrl.isEmpty) return '还没填服务器地址';
    final uri = Uri.tryParse(cleaned.baseUrl);
    if (uri == null) return '服务器地址解析不出来';
    if (uri.scheme != 'https') {
      return '服务器地址要以 https:// 开头（这条管线只走 HTTPS）';
    }
    if (uri.host.isEmpty) return '服务器地址里没有主机名或 IP';
    if (uri.path.isNotEmpty && uri.path != '/') {
      return '服务器地址不要带路径，只填主机与端口';
    }
    if (uri.hasQuery || uri.hasFragment) {
      return '服务器地址不要带查询参数或锚点';
    }

    final pin = cleaned.fingerprint;
    if (pin.isEmpty) return '还没填服务器证书指纹';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(pin)) {
      return '证书指纹要是 64 位十六进制（允许用冒号分组）';
    }

    return null;
  }

  /// 配置是否齐全（能发请求）。
  bool get isConfigured => validate() == null;

  /// 地址解析出来的 URI（没填好时为 `null`）。
  Uri? get baseUri => Uri.tryParse(normalized().baseUrl);

  /// 主机名或 IP（证书里的 SAN 必须对得上它）。
  String get host => baseUri?.host ?? '';

  /// 端口（`https://host` 不写端口时是 443）。
  int get port => baseUri?.port ?? 443;

  /// 给界面显示用的 `host:port`。
  String get displayHost {
    final uri = baseUri;
    if (uri == null) return '';
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  ServerBackupConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? fingerprint,
  }) =>
      ServerBackupConfig(
        enabled: enabled ?? this.enabled,
        baseUrl: baseUrl ?? this.baseUrl,
        fingerprint: fingerprint ?? this.fingerprint,
      );

  /// 写进 `ui_prefs.json` 的形态（**只有非敏感项**）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'baseUrl': baseUrl,
        'fingerprint': fingerprint,
      };

  static String _trimTrailingSlash(String value) {
    var out = value;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
