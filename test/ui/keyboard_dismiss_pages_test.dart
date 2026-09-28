import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/platform/ai_client.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/more/search_page.dart';
import 'package:guideline/ui/projects/ai_settings_page.dart';
import 'package:guideline/ui/projects/handoff_preview_page.dart';

/// 「键盘收起 = 收掉这次输入会话」在**其余输入口**上的接线（ADR-086 / ADR-087）。
///
/// 灵感页那条主诉（打一半字、按返回键收键盘、之后碰哪儿键盘都回来）见
/// `keyboard_dismiss_test.dart`；这里守的是"同一类缺陷不许留在别处"。语义分两档：
///
/// | 输入口 | 收键盘的含义 |
/// |---|---|
/// | 就地确认式（标题栏改名、页内编辑器） | **等于按保存 / 确认** |
/// | 页面级 / 常驻（正文编辑页、设置页、搜索框、速记框） | **只放掉焦点**，落盘仍归页面上的按键 |
///
/// 为什么非要放掉焦点：系统返回键只收掉"输入连接"、**焦点还留在框上**，
/// 之后任何一次重建都会让 `EditableText` 回头补一次输入连接 —— 键盘自己就回来了。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_kb_pages');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(
      dataDirectoryOverride: tempDir,
      // AI 设置页首次构建时要读一次安全存储；真实现是平台通道，测试里没人应答，
      // 页面会一直停在 loading（转圈的动画让 `pumpAndSettle` 等到超时）。
      credentialStore: _FakeCredentials(),
    );
  }

  /// 真机顺序：框先拿到焦点（键盘弹出来）→ 用户按返回键（键盘收起 = insets 归零）。
  ///
  /// 顺序不能反：反了护栏看不到"从有到无"那一次跳变（它只认跳变）。
  Future<void> dismissKeyboard(WidgetTester tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
  }

  FocusNode focusOf(WidgetTester tester, Finder field) =>
      tester.widget<TextField>(field).focusNode!;

  testWidgets('搜索页：收键盘只放焦点，查询与结果一个都不动', (tester) async {
    final app = await boot();
    app.run(() => app.ws.createProject(title: '指南线'));

    await tester.pumpWidget(MaterialApp(home: SearchPage(app: app)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '指南');
    await tester.pumpAndSettle();
    expect(focusOf(tester, find.byType(TextField)).hasFocus, isTrue, reason: '正在搜');

    await dismissKeyboard(tester);

    expect(
      focusOf(tester, find.byType(TextField)).hasFocus,
      isFalse,
      reason: '收键盘必须放焦点 —— 不放的话，之后碰任何一处键盘都会自己弹回来',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '指南',
      reason: '搜索框是常驻的，内容不许被收键盘清掉',
    );
    expect(find.text('指南线'), findsWidgets, reason: '结果也不该因为收键盘而变');
  });

  testWidgets('项目详情页：标题栏改名收键盘 = 按保存（就地确认式）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '老名字');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('老名字').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '新名字');
    await tester.pumpAndSettle();
    await dismissKeyboard(tester);

    expect(
      app.ws.findProject(project.id)!.title,
      '新名字',
      reason: '这个框是就地确认式的改名：收键盘 = 按保存（与页内编辑器同一条路）',
    );
    expect(find.text('新名字'), findsOneWidget, reason: '输入框已经变回标题文字');
  });

  testWidgets('AI 设置页：收键盘只放焦点，写盘仍归「保存」', (tester) async {
    final app = await boot();
    // 这一页比默认的 800×600 测试窗口长，三个框都要构建出来（与 ai_settings_test 同一手法）
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final beforeUrl = app.prefs.aiBaseUrl;

    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(app: app)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'https://example.com/v1');
    await tester.pumpAndSettle();
    final focus = focusOf(tester, find.byType(TextField).at(0));
    expect(focus.hasFocus, isTrue);

    await dismissKeyboard(tester);

    expect(focus.hasFocus, isFalse, reason: '收键盘 = 退出这次输入，焦点要放掉');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      'https://example.com/v1',
      reason: '字留着，再点一下能接着改',
    );
    expect(
      app.prefs.aiBaseUrl,
      beforeUrl,
      reason: '收键盘不是"存好了"：写盘只由右上角「保存」决定',
    );
  });

  testWidgets('交付件正文页：收键盘只放焦点，草稿不动、也不导出', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '一个目标');

    await tester.pumpWidget(
      MaterialApp(
        home: HandoffPreviewPage(
          app: app,
          projectId: project.id,
          projectTitle: project.title,
          markdown: '# 原稿',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# 我改过的稿子');
    await tester.pumpAndSettle();
    final focus = focusOf(tester, find.byType(TextField));
    expect(focus.hasFocus, isTrue);

    await dismissKeyboard(tester);

    expect(focus.hasFocus, isFalse, reason: '收键盘 = 退出这次输入，焦点要放掉');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '# 我改过的稿子',
      reason: '正文是自己改的草稿，收键盘不动它一个字',
    );
    expect(find.text('导出为 .md'), findsOneWidget, reason: '导出仍是右上角那一颗按钮的事');
  });
}

/// 空的安全存储：只为让设置页那次读取**当场返回**（真实现是平台通道）。
class _FakeCredentials implements AiCredentialStore {
  String? _value;

  @override
  Future<String?> readApiKey() async => _value;

  @override
  Future<void> writeApiKey(String value) async => _value = value;

  @override
  Future<void> clearApiKey() async => _value = null;
}
