import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/main.dart';

/// **Flutter 内置组件的文案要是中文**（2026-10-02 加）。
///
/// 起因（审查发现 🟡）：关于弹窗上那两颗按钮一直写着英文
/// "View licenses" / "Close"，而应用自己的每一句文案都是中文 ——
/// 整个界面唯一一处没本地化的地方。
///
/// 根因不是文案写错，而是 `pubspec.yaml` 里**没有 `flutter_localizations`**，
/// `MaterialApp` 也没声明 `localizationsDelegates` / `locale`。
/// Flutter 的内置文案（对话框按钮、日期选择器、`AboutDialog` 的两颗按钮……）
/// 默认只有英文，得靠这个包把 `MaterialLocalizations` 换成中文实现。
///
/// 为什么要一条机器守卫：这两颗按钮**应用代码里一个字都没写** ——
/// 它们由 `AboutDialog` 从 `MaterialLocalizations` 取。所以有人把
/// `localizationsDelegates` 摘掉时，应用自己的测试全绿、
/// `analyze` 也全绿，只有真机上点开「关于」才看得出来又变回英文了。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guideline_l10n_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(GuidelineApp(controller: app));
    await tester.pumpAndSettle();
  }

  testWidgets('关于弹窗的两颗按钮是中文，不是 "View licenses" / "Close"', (tester) async {
    await pumpApp(tester);

    // 进「更多」→ 点标题栏右侧的「关于」
    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    // 弹窗本体在（版本号那一行）
    expect(find.text('Guide Line'), findsWidgets);

    expect(
      find.text('查看许可'),
      findsOneWidget,
      reason: 'AboutDialog 的 licenses 按钮要走 MaterialLocalizations 的中文实现',
    );
    expect(
      find.text('关闭'),
      findsOneWidget,
      reason: 'AboutDialog 的 close 按钮同理',
    );
    expect(
      find.text('View licenses'),
      findsNothing,
      reason: '英文串不该再出现 —— 出现就说明 localizationsDelegates 被摘了',
    );
    expect(find.text('Close'), findsNothing);
  });

  testWidgets('MaterialLocalizations 解析到的是中文实现', (tester) async {
    await pumpApp(tester);

    final context = tester.element(find.byType(Scaffold).first);
    final l10n = MaterialLocalizations.of(context);
    expect(l10n.viewLicensesButtonLabel, '查看许可');
    expect(l10n.closeButtonLabel, '关闭');
    // 再取一个与「关于」无关的内置文案，证明是**整套**换成了中文，
    // 不是只有那两颗按钮被单独处理过。
    expect(l10n.cancelButtonLabel, '取消');
    expect(l10n.okButtonLabel, '确定');
  });
}
