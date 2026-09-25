import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/ai_config.dart';
import 'package:guideline/platform/ai_client.dart';

/// 记下最后一次收到的素材，便于断言"发出去了什么"。
late PromptInput? lastInput;
late AiConfig? lastConfig;

/// 假生成器：把调用透传给测试给的函数，同时记下入参与配置。
class FakeGenerator implements AiTextGenerator {
  FakeGenerator(this.onCall);

  final Future<String> Function(AiConfig config, PromptInput input) onCall;

  @override
  Future<String> summarizeChecklist({
    required AiConfig config,
    required PromptInput input,
  }) {
    lastConfig = config;
    lastInput = input;
    return onCall(config, input);
  }
}

/// 假凭据存储：内存里放一个值，用来验"Key 走安全存储、不进偏好"。
class FakeCredentials implements AiCredentialStore {
  FakeCredentials([this._value]);

  String? _value;

  @override
  Future<String?> readApiKey() async => _value;

  @override
  Future<void> writeApiKey(String value) async => _value = value;

  @override
  Future<void> clearApiKey() async => _value = null;
}

/// AI 整理的编排层（设计文档 §2.2）。
///
/// 全部用**假的平台实现**：不打真实网络，所以这些用例又快又稳。
/// 重点验的是护栏，不是"能不能连上模型"：
///   · payload 里**只有**名称 / 目的 / 清单，绝不能夹带灵感与任务；
///   · 生成的结果**先返回、不写库**（写回要用户确认）；
///   · 失败时不留半截状态；
///   · `apiKey` 进安全存储，**不进偏好文件**（那文件会进备份与导出）。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_ai_test');
    lastInput = null;
    lastConfig = null;
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot({
    required Future<String> Function(AiConfig, PromptInput) generate,
    AiCredentialStore? credentials,
  }) async {
    return AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      aiGenerator: FakeGenerator(generate),
      credentialStore: credentials ?? FakeCredentials('sk-test'),
    );
  }

  test('只发项目名称 / 目的 / 清单条目 —— 灵感与任务一个字都不发', () async {
    final app = await boot(generate: (_, _) async => '整理好的说明');
    final project = app.ws.createProject(title: '知识库');
    app.run(() => app.ws.updateProject(project.id, purpose: '别让灵感散落'));
    app.run(() => app.ws.addProjectItem(project.id, '第一条'));
    app.run(() => app.ws.addProjectItem(project.id, '第二条'));
    app.run(() => app.ws.captureInspiration('这条灵感不该被发出去'));
    final event = app.ws.createEvent(name: '不该被发出去的事件');
    app.ws.createTask(eventId: event.id, title: '不该被发出去的任务');

    final result = await app.summarizeProjectItems(project.id);

    expect(result.error, isNull);
    expect(result.text, '整理好的说明');
    expect(lastInput!.projectTitle, '知识库');
    expect(lastInput!.purpose, '别让灵感散落');
    expect(lastInput!.items.map((i) => i.text), <String>['第一条', '第二条']);
    expect(lastInput!.items.every((i) => !i.done), isTrue);

    // 把实际发出去的内容拼成一段文本，逐项确认敏感内容不在里面
    final sent = <String>[
      lastInput!.projectTitle,
      lastInput!.purpose,
      ...lastInput!.items.map((i) => i.text),
    ].join('\n');
    for (final secret in <String>['这条灵感不该被发出去', '不该被发出去的事件', '不该被发出去的任务']) {
      expect(sent, isNot(contains(secret)), reason: '$secret 不该进入请求');
    }
  });

  test('勾选状态会一起发出去（AI 要知道哪些已经做了）', () async {
    final app = await boot(generate: (_, _) async => 'ok');
    final project = app.ws.createProject(title: '带勾选');
    final done = app.ws.addProjectItem(project.id, '已做完的');
    app.ws.addProjectItem(project.id, '没做的');
    app.run(() => app.ws.setProjectItemDone(project.id, done.id, true));

    await app.summarizeProjectItems(project.id);

    expect(
      lastInput!.items.map((i) => i.done),
      <bool>[true, false],
    );
  });

  test('生成的结果**不写库**：正文保持原样，等用户确认', () async {
    final app = await boot(generate: (_, _) async => '模型写的一段说明');
    final project = app.ws.createProject(title: '待确认');
    app.run(() => app.ws.updateProject(project.id, implementation: '原来的正文'));
    app.run(() => app.ws.addProjectItem(project.id, '一条'));

    final result = await app.summarizeProjectItems(project.id);

    expect(result.text, '模型写的一段说明');
    expect(
      app.ws.findProject(project.id)!.implementation,
      '原来的正文',
      reason: '生成与写回必须分开 —— 模型可能编造，得先让人核对',
    );
  });

  test('清单为空时不去联网，直接给可读提示', () async {
    var called = false;
    final app = await boot(generate: (_, _) async {
      called = true;
      return '不该被调用';
    });
    final project = app.ws.createProject(title: '空清单');

    final result = await app.summarizeProjectItems(project.id);

    expect(called, isFalse, reason: '没东西可整理就不该发请求');
    expect(result.error, contains('清单是空的'));
  });

  test('没配好时不去联网，提示可以直接显示给用户', () async {
    var called = false;
    final app = await AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      aiGenerator: FakeGenerator((_, _) async {
        called = true;
        return 'x';
      }),
      credentialStore: FakeCredentials(), // 没有 Key
    );
    final project = app.ws.createProject(title: '未配置');
    app.run(() => app.ws.addProjectItem(project.id, '一条'));

    final result = await app.summarizeProjectItems(project.id);

    expect(called, isFalse);
    expect(result.error, contains('API Key'));
  });

  test('模型报错时如实返回文案，且不留半截状态', () async {
    final app = await boot(
      generate: (_, _) async => throw const AiRequestException('额度用完或被限流了'),
    );
    final project = app.ws.createProject(title: '会失败');
    app.run(() => app.ws.updateProject(project.id, implementation: '原正文'));
    app.run(() => app.ws.addProjectItem(project.id, '一条'));

    final result = await app.summarizeProjectItems(project.id);

    expect(result.text, isNull);
    expect(result.error, '额度用完或被限流了');
    expect(app.ws.findProject(project.id)!.implementation, '原正文');
  });

  test('apiKey 进安全存储，**不进偏好文件**', () async {
    final credentials = FakeCredentials();
    final app = await boot(generate: (_, _) async => 'x', credentials: credentials);

    final error = await app.saveAiConfig(
      const AiConfig(baseUrl: 'https://example.com/', apiKey: 'sk-secret', model: 'my-model'),
    );

    expect(error, isNull);
    expect(await credentials.readApiKey(), 'sk-secret');
    expect(app.prefs.aiBaseUrl, 'https://example.com', reason: '末尾斜杠要被收掉');
    expect(app.prefs.aiModel, 'my-model');

    // 偏好文件的 JSON 里不能出现 Key
    final prefsJson = app.prefs.toJson();
    expect(prefsJson.containsKey('apiKey'), isFalse);
    expect(prefsJson.values.join(), isNot(contains('sk-secret')));
  });

  test('保存空 Key 表示清除（不把空串写进安全存储）', () async {
    final credentials = FakeCredentials('sk-old');
    final app = await boot(generate: (_, _) async => 'x', credentials: credentials);

    await app.saveAiConfig(
      const AiConfig(baseUrl: AiConfig.defaultBaseUrl, apiKey: '', model: 'm'),
    );

    expect(await credentials.readApiKey(), isNull);
    expect((await app.readAiConfig()).isConfigured, isFalse);
  });

  test('配置校验：地址与模型名的常见错误都能说清', () {
    String? reasonOf(String url, String key, String model) => AiConfig(
          baseUrl: url,
          apiKey: key,
          model: model,
        ).validate();

    expect(reasonOf('', 'k', 'm'), contains('API 地址'));
    expect(reasonOf('example.com', 'k', 'm'), contains('http'));
    expect(reasonOf('ftp://example.com', 'k', 'm'), contains('http'));
    expect(reasonOf('https://example.com', '', 'm'), contains('API Key'));
    expect(reasonOf('https://example.com', 'k', ''), contains('模型'));
    expect(reasonOf('https://example.com', 'k', 'm'), isNull);
  });

  group('请求地址怎么拼（连不上的第一嫌疑）', () {
    String urlOf(String base) =>
        AiConfig(baseUrl: base, apiKey: 'k', model: 'm').chatCompletionsUrl;

    test('根地址自动补 /chat/completions（官方文档的 base_url 就长这样）', () {
      expect(urlOf('https://api.deepseek.com'), 'https://api.deepseek.com/chat/completions');
    });

    test('末尾多余斜杠被收掉，不会拼出双斜杠', () {
      expect(urlOf('https://api.deepseek.com/'), 'https://api.deepseek.com/chat/completions');
      expect(urlOf('https://api.deepseek.com///'), 'https://api.deepseek.com/chat/completions');
    });

    test('**已经带了路径就不再补**（粘 curl 命令的人填的就是完整地址）', () {
      expect(
        urlOf('https://api.deepseek.com/chat/completions'),
        'https://api.deepseek.com/chat/completions',
        reason: '补两次会变成 …/chat/completions/chat/completions，服务端只回 404',
      );
    });

    test('带版本前缀的地址照常补后缀（很多兼容端点写 /v1）', () {
      expect(urlOf('https://example.com/v1'), 'https://example.com/v1/chat/completions');
    });

    test('前后空格被去掉（粘贴常常带进来）', () {
      expect(urlOf('  https://api.deepseek.com  '), 'https://api.deepseek.com/chat/completions');
    });
  });

  test('提示词明确要求"只整理、不新增"', () {    expect(HttpAiTextGenerator.systemPrompt, contains('只整理，不新增'));
    expect(HttpAiTextGenerator.systemPrompt, contains('不要用列表'));
  });

  test('用户消息把清单写成 GitHub 任务列表，方便模型理解勾选状态', () {
    final prompt = HttpAiTextGenerator.buildUserPrompt(
      const PromptInput(
        projectTitle: '标题',
        purpose: '',
        items: <({String text, bool done})>[
          (text: '做了的', done: true),
          (text: '没做的', done: false),
        ],
      ),
    );

    expect(prompt, contains('项目名称：标题'));
    expect(prompt, contains('项目目的：（未填写）'));
    expect(prompt, contains('- [x] 做了的'));
    expect(prompt, contains('- [ ] 没做的'));
  });
}
