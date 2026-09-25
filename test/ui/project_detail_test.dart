import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/color_picker.dart';

/// 项目详情页的标题栏与报错提示（实机反馈）：
///   · 标题旁立一根**标识色竖条**（没设色就是灰条），与项目树行首同一个控件；
///   · 正文里不再重复一个「名称」字段，改名收进标题右侧的三个点，
///     点「重命名」后标题栏原地变成输入框，带确认 / 取消；
///   · 子节点没做完就点「已完成」时那句提示，浅色底上必须是深色字。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_detail_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  /// 从项目 Tab 进到指定项目的详情页（底栏那一项与标题栏文案不同名，直接按底栏找）。
  Future<void> openProject(WidgetTester tester, AppController app, String title) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  /// 详情页标题栏里的那根竖条。
  ///
  /// `find.byType` 默认跳过 offstage：被详情页盖住的 Tab 页不在结果里，
  /// 所以这里不用再按路由去区分。
  Finder titleBar() => find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(ProjectColorBar),
      );

  Color? renderedBarColor(WidgetTester tester) {
    final container = tester.widget<Container>(
      find.descendant(of: titleBar(), matching: find.byType(Container)),
    );
    return (container.decoration as BoxDecoration?)?.color;
  }

  testWidgets('详情页标题旁有标识色竖条；没设色的项目用灰条补齐', (tester) async {
    final app = await boot();
    final colored = app.ws.createProject(title: '有色的项目');
    final plain = app.ws.createProject(title: '没色的项目');
    app.run(() => app.ws.setProjectColor(colored.id, '#336699'));
    app.run(() => app.ws.setProjectColor(plain.id, null));

    await openProject(tester, app, '有色的项目');

    expect(titleBar(), findsOneWidget);
    expect(tester.widget<ProjectColorBar>(titleBar()).color, '#336699');
    expect(renderedBarColor(tester), colorOfHex('#336699'));
    expect(find.text('名称'), findsNothing, reason: '标题栏已经写着名字了，正文里不再重复');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('没色的项目').first);
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.text('没色的项目'))).colorScheme;
    expect(renderedBarColor(tester), scheme.outlineVariant, reason: '没设色 = 中性灰条');
  });

  testWidgets('重命名收进三个点：标题栏原地变输入框，带确认 / 取消', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '老名字');

    await openProject(tester, app, '老名字');

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('保存'), findsOneWidget);
    expect(find.byTooltip('取消'), findsOneWidget);

    // 改一半放弃：不写盘，标题回到原样
    await tester.enterText(find.byType(TextField).first, '不该保存的名字');
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(project.id)!.title, '老名字');
    expect(find.text('不该保存的名字'), findsNothing);
    expect(find.text('老名字'), findsOneWidget);

    // 改完确认：真的写盘，标题栏跟着变
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '新名字');
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(project.id)!.title, '新名字');
    expect(find.text('新名字'), findsOneWidget);
  });

  testWidgets('重命名清空时不提交：保持原名，不把标题清没', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '别弄丢我');

    await openProject(tester, app, '别弄丢我');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.title, '别弄丢我');
    expect(find.text('别弄丢我'), findsOneWidget);
  });

  testWidgets('子节点没做完就点「已完成」：拦下来的那句提示是深色字', (tester) async {
    final app = await boot();
    final parent = app.ws.createProject(title: '父项目');
    app.ws.createProject(title: '子项目', parentId: parent.id);

    await openProject(tester, app, '父项目');
    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();

    final message = find.textContaining('还有 1 个子节点未处理');
    expect(message, findsOneWidget);

    // 底色是浅色的 errorContainer，默认文字色是 near-white 的 inverseOnSurface ——
    // 那样等于看不见，所以必须自己指定"画在这个底色上"的前景色
    final scheme = Theme.of(tester.element(find.text('已完成'))).colorScheme;
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.backgroundColor, scheme.errorContainer);
    expect(
      tester.widget<Text>(message).style?.color,
      scheme.onErrorContainer,
      reason: '浅色底上的默认文字色近乎纯白，得显式换成深色的 onErrorContainer',
    );
  });
}
