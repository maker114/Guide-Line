import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/models/ai_config.dart';

/// 平台适配层：**AI 联网**（《定义与边界》§10）。
///
/// 这是全应用**唯一**发网络请求的地方，也是除数据目录 / 文件选择器外
/// 唯一 import 插件的地方（ADR-024）。业务层只认下面两个接口，
/// 测试时注入假实现即可，不需要真的联网。
///
/// 三条硬边界（都在《定义与边界》§10 里逐条写死）：
///   1. **请求只发到用户自己填的 `baseUrl`**，没有任何硬编码的第三方地址；
///   2. **只发项目标题 / 目的 / 清单条目**（+ 一段固定提示词）——
///      灵感原文、事件任务、其它项目、设备信息一律不发；
///   3. **提示词与返回原文都不落盘**，只有用户确认后的结果写进 `implementation`。
abstract interface class AiTextGenerator {
  /// 把清单整理成一段通顺说明。失败抛 [AiRequestException]。
  Future<String> summarizeChecklist({
    required AiConfig config,
    required PromptInput input,
  });
}

/// 生成提示词需要的素材（**只有这些会被发出去**）。
class PromptInput {
  const PromptInput({
    required this.projectTitle,
    required this.purpose,
    required this.items,
  });

  final String projectTitle;
  final String purpose;
  final List<({String text, bool done})> items;
}

/// 联网失败的统一异常：文案要能直接给用户看。
class AiRequestException implements Exception {
  const AiRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 凭据存储：`apiKey` 单独放这里（**不进 `ui_prefs.json`、不进导出、不进备份**）。
abstract interface class AiCredentialStore {
  Future<String?> readApiKey();

  Future<void> writeApiKey(String value);

  Future<void> clearApiKey();
}

/// 用 `flutter_secure_storage` 存 `apiKey`（Android 走 Keystore）。
class SecureAiCredentialStore implements AiCredentialStore {
  const SecureAiCredentialStore();

  static const String _key = 'guideline.ai.apiKey';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    // v11 起默认就是 AES-GCM + RSA 包裹密钥（API 23+），不用再显式指定；
    // 特意**不开** `resetOnError`：那会在解密异常时把已存的 Key 永久清掉，
    // 而偶发失败更合理的处理是"这次读不出来"（下面 read 已经这么做）。
    aOptions: AndroidOptions(resetOnError: false),
  );

  @override
  Future<String?> readApiKey() async {
    try {
      final value = await _storage.read(key: _key);
      if (value == null || value.trim().isEmpty) return null;
      return value.trim();
    } catch (_) {
      // 读不出来就当没配置：部分 ROM 上 Keystore 会偶发失败，不该让界面崩
      return null;
    }
  }

  @override
  Future<void> writeApiKey(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> clearApiKey() => _storage.delete(key: _key);
}

/// OpenAI 兼容的 `/chat/completions` 实现（DeepSeek 走的就是这套）。
class HttpAiTextGenerator implements AiTextGenerator {
  const HttpAiTextGenerator();

  /// 超时 30 秒：再长用户已经在等，再短容易在弱网下误报失败。
  static const Duration timeout = Duration(seconds: 30);

  @override
  Future<String> summarizeChecklist({
    required AiConfig config,
    required PromptInput input,
  }) async {
    final error = config.validate();
    if (error != null) throw AiRequestException(error);

    final uri = Uri.parse(config.chatCompletionsUrl);
    final body = jsonEncode(<String, dynamic>{
      'model': config.model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'system', 'content': systemPrompt},
        <String, String>{'role': 'user', 'content': buildUserPrompt(input)},
      ],
      // 低温度：这是"整理"，不是"创作"，要稳不要花
      'temperature': 0.3,
      'stream': false,
    });

    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${config.apiKey}',
            },
            body: body,
          )
          .timeout(timeout);
    } on SocketException catch (error) {
      // 注意：**权限缺失在 Dart 侧也表现为 SocketException**（Android 没给
      // INTERNET 权限时连不上任何地址）。所以文案要把"权限"一起提一句 ——
      // 这个坑真踩过：debug 包有权限、release 包没有，于是"调试时好好的、
      // 装出来就连不上"，只看日志根本想不到是清单里少了一行。
      throw AiRequestException(
        '连不上这个地址（${error.osError?.message ?? error.message}）\n'
        '检查网络与该地址是否可达；若怎么都连不上，确认安装包的联网权限没有被去掉',
      );
    } on HttpException {
      throw const AiRequestException('网络请求失败，稍后再试');
    } catch (error) {
      // 包含 TimeoutException：文案要说明"可能已经超时"而不是笼统的失败
      throw AiRequestException('请求超时或中断（$error）');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const AiRequestException('密钥不对或没有权限，去设置里检查 API Key');
    }
    if (response.statusCode == 429) {
      throw const AiRequestException('额度用完或被限流了，稍后再试或换一个 Key');
    }
    if (response.statusCode == 404) {
      // 404 最常见的原因是地址拼错了。把**实际请求的地址**报出来，
      // 用户一眼就能看出是多写了路径还是少了域名 —— 只说"404"没法定位。
      throw AiRequestException('地址不对（404）：${uri.toString()}\n去设置里核对 API 地址');
    }
    if (response.statusCode >= 400) {
      // 有些网关会用 HTML 报错页（"没有这个网站"之类），直接贴出来很难看，
      // 尽量只取纯文本部分
      throw AiRequestException('服务返回 ${response.statusCode}：${_brief(response.body)}');
    }

    return _extractContent(response.body);
  }

  static String _extractContent(String rawBody) {
    final Object? root;
    try {
      root = jsonDecode(rawBody);
    } catch (_) {
      throw const AiRequestException('返回的不是合法 JSON，可能这个地址不是 chat/completions 接口');
    }
    if (root is! Map) throw const AiRequestException('返回结构看不懂，缺少 choices');

    final choices = root['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiRequestException('模型没有返回内容（choices 为空）');
    }
    final first = choices.first;
    if (first is! Map) throw const AiRequestException('返回结构看不懂');
    final message = first['message'];
    if (message is! Map) throw const AiRequestException('返回结构看不懂，缺少 message');

    final content = message['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const AiRequestException('模型返回了空内容');
    }
    return _stripCodeFence(content.trim());
  }

  /// 模型爱把整段答案包在 ``` 里，直接写进正文会带出一堆反引号。
  static String _stripCodeFence(String text) {
    if (!text.startsWith('```')) return text;
    final lines = text.split('\n');
    if (lines.length < 2) return text;
    lines.removeAt(0);
    if (lines.isNotEmpty && lines.last.trim().startsWith('```')) lines.removeLast();
    return lines.join('\n').trim();
  }

  static String _brief(String body) {
    // 网关的报错页常常是 HTML，把标签去掉再截断，免得界面上出现一堆尖括号
    final stripped = body
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (stripped.isEmpty) return '（返回内容为空）';
    return stripped.length <= 160 ? stripped : '${stripped.substring(0, 160)}…';
  }

  /// 固定提示词：要求它只做整理，不许新增事实。
  ///
  /// 注意：这段里**不能用 Markdown 的加粗记号**（`test/ui/no_markdown_in_ui_test.dart`
  /// 会扫全 `lib/` 的运行时字符串）。它虽然只发给模型、不会显示给用户，
  /// 但那条测试是故意做成"一刀切"的 —— 留着例外就等于给误用开口子，
  /// 要强调就用「」或换行分点。
  static const String systemPrompt = '''
你是一个中文写作助手，任务是「整理」，不是「创作」。

用户会给你一个项目的名称、"有什么问题 / 思路"，以及一份实现清单。请把这份清单改写成一段连贯、
通顺的中文说明，讲清「这个项目打算怎么做」。要求：

1. 只整理，不新增：不得添加清单里没有的功能、步骤、数据或结论。
   清单里没提到的东西，一个字都不要写；
2. 已完成的条目用「已经……」这类表述体现，未完成的用「接下来要……」或「还需要……」；
3. 用一段或两段连续的文字，不要用列表、不要加标题、不要用 Markdown 记号；
4. 不要称呼「用户」或「你」，直接陈述这个项目本身；
5. 只输出整理后的正文，前后不要任何解释、说明或客套话。''';

  /// 用户消息：**只有项目标题、"有什么问题 / 思路"与清单条目**（《定义与边界》§10 的边界）。
  /// 字段名与界面一致（Q4）：「目的」→"有什么问题 / 思路"、「待办清单」→「实现清单」——
  /// 界面上的"待办"只指事件里的任务，项目里那份叫清单。
  static String buildUserPrompt(PromptInput input) {
    final buffer = StringBuffer()
      ..writeln('项目名称：${input.projectTitle}')
      ..writeln('"有什么问题 / 思路"：${input.purpose.trim().isEmpty ? '（未填写）' : input.purpose.trim()}')
      ..writeln('实现清单：');
    for (final item in input.items) {
      buffer.writeln('- [${item.done ? 'x' : ' '}] ${item.text}');
    }
    return buffer.toString().trimRight();
  }
}
