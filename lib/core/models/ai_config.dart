/// AI 联网配置（设计文档 §2.2）。
///
/// 放 core 是因为它是**纯数据 + 纯校验**，没有网络也没有插件；
/// 真正发请求在 `lib/platform/ai_client.dart`。
///
/// 两条边界写在这里，别处不要破：
///   · [apiKey] **不进 `ui_prefs.json`**（那个文件会进滚动备份与导出），
///     它由 `flutter_secure_storage` 单独保管；
///   · 没有硬编码的第三方地址 —— 请求只会发到用户自己填的 [baseUrl]。
class AiConfig {
  const AiConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  /// 默认地址：DeepSeek 官方 API 是 OpenAI 兼容的。
  static const String defaultBaseUrl = 'https://api.deepseek.com';

  /// 默认模型名。
  ///
  /// **是 `deepseek-flash` 而不是 `deepseek-v4.1-flash`**：官方发布说明写的是
  /// "将模型名称更改为 `deepseek-flash` 即可调用最新的 V4.1 Flash 模型"，
  /// `deepseek-v4.1-flash` 这个串官方没有给。字段允许自定义是为了兼容
  /// 其它 OpenAI 兼容端点。
  static const String defaultModel = 'deepseek-flash';

  final String baseUrl;
  final String apiKey;
  final String model;

  /// 只存非敏感部分（`baseUrl` / `model`）—— `apiKey` 走安全存储。
  const AiConfig.nonSecret({required this.baseUrl, required this.model})
      : apiKey = '';

  /// 是否已经配好、可以发起请求。
  bool get isConfigured => validate() == null;

  /// 返回不可用的原因；都合法时返回 `null`。
  ///
  /// 文案要能直接显示给用户，所以写成人话。
  String? validate() {
    if (baseUrl.trim().isEmpty) return '还没填 API 地址';
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return 'API 地址要以 http:// 或 https:// 开头';
    }
    if (uri.host.isEmpty) return 'API 地址里没有主机名';
    if (apiKey.trim().isEmpty) return '还没填 API Key';
    if (model.trim().isEmpty) return '还没填模型名';
    return null;
  }

  /// 规范化：URL 去掉末尾斜杠（否则会拼出 `//chat/completions`）、
  /// 其余字段去掉前后空格。非法 URL 原样返回，交给 [validate] 报错。
  AiConfig normalized() {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return AiConfig(
      baseUrl: url,
      apiKey: apiKey.trim(),
      model: model.trim(),
    );
  }

  /// 真正要 POST 的完整地址。
  ///
  /// 大多数人只知道填"根地址"，所以这里**自动补** `/chat/completions`；
  /// 但也照顾已经把路径写进去的情况 —— 直接粘官方文档里那条 curl 命令的人
  /// 填的就是 `https://api.deepseek.com/chat/completions`，
  /// 再补一次会变成 `…/chat/completions/chat/completions`，
  /// 服务端只会回一个让人摸不着头脑的 404（"没有这个网站"）。
  ///
  /// 顺带兼容 `/v1`：不少 OpenAI 兼容端点（以及一部分中转服务）习惯带版本前缀，
  /// 这种地址末尾不是 endpoints 名，照常补后缀。
  String get chatCompletionsUrl {
    final base = normalized().baseUrl;
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  AiConfig copyWith({String? baseUrl, String? apiKey, String? model}) => AiConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );
}
