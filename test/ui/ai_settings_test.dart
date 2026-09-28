import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/ai_config.dart';
import 'package:guideline/core/store/app_paths.dart';
import 'package:guideline/platform/ai_client.dart';
import 'package:guideline/ui/projects/ai_settings_page.dart';

/// Q14：AI 设置页的「测试连接」**不许偷偷保存**。
///
/// 原来的实现是"先 `saveAiConfig` 再测"，而按钮旁边的说明只说"会真的发一次请求" ——
/// 用户测出"地址不对 / 密钥不对"之后多半直接返回，那份错配置其实已经落盘了，
/// 要等到下一次真用 AI 整理时才炸，那时他早不记得自己试过什么。
///
/// 现在测试走**临时配置**（输入框里的地址 / 模型 / Key 现拼一份去试），一个字都不写；
/// 要存下来得按右上角「保存」。这一页同时把两种生效时机讲清楚：
/// 开关即时生效，文本框按「保存」。
///
/// 注：AI 总开关本身的用例在 `ai_switch_test.dart`（那一页的另一条轴）。
void main() {
  late Directory tempDir;
  late _FakeCredentials credentials;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_ai_settings_test');
    credentials = _FakeCredentials();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot(AiTextGenerator ai) => AppController.bootstrap(
        dataDirectoryOverride: tempDir,
        aiGenerator: ai,
        credentialStore: credentials,
      );

  /// 打开设置页。窗口调高到 1000×1600 —— 这一页比默认的 800×600 测试窗口长，
  /// 调高之后所有控件都已构建、能直接点到，不必去猜该滚哪个 `Scrollable`
  /// （页里那三个 `TextField` 自己也是 `Scrollable`）。
  Future<void> openSettings(WidgetTester tester, AppController app) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(app: app)));
    await tester.pumpAndSettle();
  }

  /// 依次填「API 地址 / 模型 / API Key」。
  Future<void> fillFields(
    WidgetTester tester, {
    String? baseUrl,
    String? model,
    String? apiKey,
  }) async {
    if (baseUrl != null) await tester.enterText(find.byType(TextField).at(0), baseUrl);
    if (model != null) await tester.enterText(find.byType(TextField).at(1), model);
    if (apiKey != null) await tester.enterText(find.byType(TextField).at(2), apiKey);
    await tester.pumpAndSettle();
  }

  testWidgets('测试连接只试不存：没按「保存」时地址与 Key 都没落盘', (tester) async {
    final generator = _RecordingGenerator();
    final app = await boot(generator);
    await openSettings(tester, app);

    final beforeUrl = app.prefs.aiBaseUrl;
    final beforeModel = app.prefs.aiModel;

    await fillFields(
      tester,
      baseUrl: 'https://example.com/v1',
      model: 'deepseek-flash',
      apiKey: 'sk-typed',
    );
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    // 测的确实是**输入框里现拼的那份**（不是库里的旧配置）
    expect(generator.calls.single.baseUrl, 'https://example.com/v1');
    expect(generator.calls.single.apiKey, 'sk-typed');
    expect(generator.calls.single.model, 'deepseek-flash');

    // 但一个字都没写下去
    expect(await credentials.readApiKey(), isNull, reason: '测试不许把 Key 写进安全存储');
    expect(app.prefs.aiBaseUrl, beforeUrl, reason: '地址也不许偷偷写进偏好');
    expect(app.prefs.aiModel, beforeModel);
    final prefsFile = AppPaths(tempDir).prefsFile;
    final prefsText = prefsFile.existsSync() ? prefsFile.readAsStringSync() : '';
    expect(
      prefsText.contains('https://example.com'),
      isFalse,
      reason: '盘上的偏好文件里也不该出现这次试的地址',
    );
  });

  testWidgets('测通之后还告诉用户"还没保存"，按「保存」才真落盘', (tester) async {
    final generator = _RecordingGenerator(reply: '连接没问题');
    final app = await boot(generator);
    await openSettings(tester, app);

    await fillFields(
      tester,
      baseUrl: 'https://example.com',
      model: 'deepseek-flash',
      apiKey: 'sk-typed',
    );
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('连接没问题'), findsOneWidget);
    expect(find.textContaining('还没保存'), findsOneWidget, reason: '测通 ≠ 存好，要说出来');
    expect(await credentials.readApiKey(), isNull);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(await credentials.readApiKey(), 'sk-typed', reason: '按了保存才写');
    expect(app.prefs.aiBaseUrl, 'https://example.com');
    expect(app.prefs.aiModel, 'deepseek-flash');
  });

  testWidgets('只改地址、Key 框留空时，测试沿用已保存的那把 Key，且不改库', (tester) async {
    final generator = _RecordingGenerator();
    final app = await boot(generator);
    await app.saveAiConfig(
      const AiConfig(baseUrl: 'https://old.example.com', apiKey: 'sk-keep-me', model: 'm'),
    );
    await openSettings(tester, app);

    // 已保存的 Key 本来就不回显，所以只填地址
    await fillFields(tester, baseUrl: 'https://new.example.com');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(generator.calls.single.baseUrl, 'https://new.example.com');
    expect(
      generator.calls.single.apiKey,
      'sk-keep-me',
      reason: '框里没填就该用安全存储里那把，否则"只改地址"的人会得到"还没填 API Key"',
    );

    expect(await credentials.readApiKey(), 'sk-keep-me');
    expect(app.prefs.aiBaseUrl, 'https://old.example.com', reason: '试归试，没按保存就不改库');
  });

  testWidgets('失败时也一字不存：错地址不会被悄悄留成"当前配置"', (tester) async {
    final generator = _RecordingGenerator(failWith: '地址不对（404）：https://wrong.example.com/chat/completions');
    final app = await boot(generator);
    await openSettings(tester, app);

    final beforeUrl = app.prefs.aiBaseUrl;

    await fillFields(
      tester,
      baseUrl: 'https://wrong.example.com',
      model: 'deepseek-flash',
      apiKey: 'sk-typed',
    );
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('地址不对'), findsOneWidget);
    expect(await credentials.readApiKey(), isNull);
    expect(app.prefs.aiBaseUrl, beforeUrl, reason: '错的地址尤其不能存');
  });

  testWidgets('页面里写清两种生效时机：开关即时生效，文本框按「保存」', (tester) async {
    final app = await boot(_RecordingGenerator());
    await openSettings(tester, app);

    expect(find.textContaining('开关即时生效'), findsOneWidget);
    expect(find.textContaining('要按右上角「保存」才写入'), findsOneWidget);
    expect(find.textContaining('不会保存'), findsOneWidget, reason: '按钮旁的说明要如实');
  });
}

class _FakeCredentials implements AiCredentialStore {
  String? _value;

  @override
  Future<String?> readApiKey() async => _value;

  @override
  Future<void> writeApiKey(String value) async => _value = value;

  @override
  Future<void> clearApiKey() async => _value = null;
}

/// 记账用的假客户端：把每次请求实际用的配置留下来，
/// 才能断言"测的是输入框里现拼的那份"而不是库里存的那份。
class _RecordingGenerator implements AiTextGenerator {
  _RecordingGenerator({this.reply = '收到', this.failWith});

  final String reply;
  final String? failWith;
  final List<AiConfig> calls = <AiConfig>[];

  @override
  Future<String> summarizeChecklist({
    required AiConfig config,
    required PromptInput input,
  }) async {
    calls.add(config);
    final failure = failWith;
    if (failure != null) throw AiRequestException(failure);
    return reply;
  }

  @override
  Future<String> splitIntoItems({
    required AiConfig config,
    required PromptInput input,
  }) =>
      summarizeChecklist(config: config, input: input);
}
