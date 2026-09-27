import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/store/ui_prefs.dart';
import 'package:guideline/main.dart';
import 'package:guideline/ui/more/appearance_page.dart';
import 'package:guideline/ui/theme/app_theme.dart';

/// 「深色 / 亮色」手动开关（`ui_prefs.themeMode`）。
///
/// 从前 `MaterialApp` 只给了 `theme` / `darkTheme`、**没给 `themeMode`** ——
/// 默认值就是 `system`，于是"跟随系统"一直是唯一的行为：系统开了深色，
/// 用户想固定用亮色也没有入口。
///
/// 这条用例管两头：设置页选完**真的落到 `MaterialApp.themeMode`**，
/// 以及选完**真的写进偏好文件**（下次启动还得是这个选择）。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_theme_mode');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(GuidelineApp(controller: app));
    await tester.pumpAndSettle();
    return app;
  }

  ThemeMode currentThemeMode(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

  testWidgets('默认跟随系统', (tester) async {
    await boot(tester);
    expect(currentThemeMode(tester), ThemeMode.system);
  });

  testWidgets('外观页选「深色」→ MaterialApp 真的切过去，并且落了盘', (tester) async {
    final app = await boot(tester);
    final prefs = app.prefs;

    await tester.pumpWidget(
      MaterialApp(home: AppearancePage(app: app)),
    );
    await tester.pumpAndSettle();

    expect(find.text('深色 / 亮色'), findsOneWidget, reason: '单独成节');
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(app.prefs.themeMode, UiPrefs.themeModeDark, reason: '选择要落到偏好里');
    expect(
      app.prefs.themeId,
      prefs.themeId,
      reason: '配色与亮暗是两个维度，选亮暗不该动配色',
    );

    // 偏好是真的写进了那个文件（不是只活在内存里）
    final reloaded = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(reloaded.prefs.themeMode, UiPrefs.themeModeDark);
  });

  testWidgets('选完之后 MaterialApp.themeMode 跟着变', (tester) async {
    final app = await boot(tester);
    expect(currentThemeMode(tester), ThemeMode.system);

    app.updatePrefs(app.prefs.copyWith(themeMode: UiPrefs.themeModeLight));
    await tester.pumpAndSettle();
    expect(currentThemeMode(tester), ThemeMode.light);

    app.updatePrefs(app.prefs.copyWith(themeMode: UiPrefs.themeModeDark));
    await tester.pumpAndSettle();
    expect(currentThemeMode(tester), ThemeMode.dark);

    app.updatePrefs(app.prefs.copyWith(themeMode: UiPrefs.themeModeSystem));
    await tester.pumpAndSettle();
    expect(currentThemeMode(tester), ThemeMode.system);
  });

  test('翻译只有一处：三个取值各有对应，认不出来的按跟随系统', () {
    expect(
      themeModeOf(const UiPrefs(themeMode: UiPrefs.themeModeLight)),
      ThemeMode.light,
    );
    expect(
      themeModeOf(const UiPrefs(themeMode: UiPrefs.themeModeDark)),
      ThemeMode.dark,
    );
    expect(
      themeModeOf(const UiPrefs(themeMode: UiPrefs.themeModeSystem)),
      ThemeMode.system,
    );
    expect(
      themeModeOf(const UiPrefs(themeMode: 'wat')),
      ThemeMode.system,
      reason: '认不出来的一律按跟随系统（与 fromJson 的口径一致）',
    );
  });
}
