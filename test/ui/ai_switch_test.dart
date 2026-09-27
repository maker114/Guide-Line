import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/ai_config.dart';
import 'package:guideline/platform/ai_client.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/projects/ai_settings_page.dart';

import 'scroll_finders.dart';

/// AI 总开关（实机反馈）：关掉之后**项目里不再出现 AI 整理的入口**，
/// 但已经填好的地址 / 模型 / Key 一条都不清 —— 开关只决定"显不显示"。
void main() {
  late Directory tempDir;
  late _FakeCredentials credentials;

  final config = const AiConfig(
    baseUrl: 'https://example.com',
    apiKey: 'sk-keep-me',
    model: 'm',
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_ai_switch_test');
    credentials = _FakeCredentials();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      aiGenerator: _NoopGenerator(),
      credentialStore: credentials,
    );
  }

  /// 开 App 并进到某个项目的详情页。
  Future<void> openProject(WidgetTester tester, AppController app, String title) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  /// 滚到清单区（AI 入口在那一块的最下面）。
  Future<void> scrollToChecklist(WidgetTester tester, String anchor) async {
    await tester.scrollUntilVisible(find.text(anchor), 150, scrollable: verticalScrollable);
    await tester.pumpAndSettle();
  }

  testWidgets('默认开着：清单里有 AI 整理入口', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目甲');
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));

    await openProject(tester, app, '项目甲');
    await scrollToChecklist(tester, 'AI 整理成「如何解决」');

    expect(find.text('AI 整理成「如何解决」'), findsOneWidget);
    expect(app.aiEnabled, isTrue);
  });

  testWidgets('关掉之后：清单里不再有 AI 入口，Key 与地址都还在', (tester) async {
    final app = await boot();
    await app.saveAiConfig(config);
    final project = app.ws.createProject(title: '项目乙');
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));
    app.setAiEnabled(false);

    await openProject(tester, app, '项目乙');
    await scrollToChecklist(tester, '添加条目');

    expect(find.text('AI 整理成「如何解决」'), findsNothing, reason: '关掉就不该再出现 AI 整理的字样');
    expect(await credentials.readApiKey(), 'sk-keep-me', reason: 'Key 不清');
    expect(app.prefs.aiBaseUrl, 'https://example.com', reason: '地址也不清');
    expect(app.prefs.aiModel, 'm');
  });

  testWidgets('设置页的开关能开也能关，翻完仍然是同一份配置', (tester) async {
    final app = await boot();
    await app.saveAiConfig(config);

    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.text('启用 AI 整理'), findsOneWidget);
    expect(find.text('已保存，重新输入可替换'), findsOneWidget, reason: 'Key 已经存着');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(app.aiEnabled, isFalse);
    expect(await credentials.readApiKey(), 'sk-keep-me');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(app.aiEnabled, isTrue);
    expect(await credentials.readApiKey(), 'sk-keep-me', reason: '开关来回翻也不动 Key');
    expect(app.prefs.aiBaseUrl, 'https://example.com');
  });

  testWidgets('更多页里那一行还留着（否则关掉就再也打不开了），副标题写明已关闭', (tester) async {
    final app = await boot();
    app.setAiEnabled(false);

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('更多')),
    );
    await tester.pumpAndSettle();

    // 「更多」是一张会变长的列表，靠后的条目在小屏上不会被构建出来 —— 先滚到它
    await tester.scrollUntilVisible(
      find.text('AI 整理'),
      150,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('AI 整理'), findsOneWidget);
    expect(find.textContaining('已关闭'), findsOneWidget);
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

class _NoopGenerator implements AiTextGenerator {
  @override
  Future<String> summarizeChecklist({
    required AiConfig config,
    required PromptInput input,
  }) async =>
      '不该被调用';
}
