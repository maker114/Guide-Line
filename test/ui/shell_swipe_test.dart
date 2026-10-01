import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/projects/project_tab.dart';
import 'package:guideline/ui/shell_title.dart';

/// 外壳的**左右滑动切页**（实机反馈）：四个页签排成一排，滑过去就换页，
/// 底栏那个胶囊跟着手指走。
///
/// 与"点底栏切页"是两条入口、同一个结果 —— 两条都要钉住。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_swipe_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.ws.createProject(title: '一个项目');
    app.ws.createEvent(name: '一个事件');
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    return app;
  }

  /// 横向滑过 [pages] 页（正数向左、往后翻；负数向右、往前翻）。
  ///
  /// 一次手势只翻一页，所以要翻两页就滑两次 —— 与真机上一致。
  Future<void> swipe(WidgetTester tester, int pages) async {
    final width = tester.getRect(find.byType(PageView)).width;
    for (var i = 0; i < pages.abs(); i += 1) {
      await tester.drag(
        find.byType(PageView),
        Offset(pages > 0 ? -width * 0.6 : width * 0.6, 0),
      );
      await tester.pumpAndSettle();
    }
  }

  /// 胶囊左端**相对底栏**的位置（底栏自己离屏幕左边还有 20dp 外边距）。
  double pillLeft(WidgetTester tester) {
    final bar = tester.getRect(find.byType(AppBottomNav));
    return tester.getRect(find.byKey(navIndicatorKey)).left - bar.left;
  }

  /// `ShellTitle` 自己的子树 —— **只有标题文字与它的过渡图层**在这里。
  ///
  /// 用途是量标题的过渡（`Opacity` / `Transform` 的层数、位移、不透明度），
  /// 以及"这一页此刻的标题是哪句话"。
  ///
  /// **`AppBar` 右侧那些动作入口不在这个子树里**：`title` 与 `actions` 是 `AppBar`
  /// 的两个并列槽位，`关于` 那个 `TextButton` 挂在 `actions` 上（见
  /// `lib/ui/app_shell.dart` 的 mobile 分支）。要找它用 [inAppBar]。
  Finder inTitle(Finder matching) =>
      find.descendant(of: find.byType(ShellTitle), matching: matching);

  /// 标题栏**整条**（`AppBar`）里的某个东西：`title` 槽与 `actions` 槽都算在内。
  ///
  /// 与 [inTitle] 的分工：**"标题文字"用 `inTitle`，"标题栏上的入口"用这个。**
  /// 拿 `inTitle` 去找 `actions` 里的东西必然找不到 —— 那是并列，不是后代。
  Finder inAppBar(Finder matching) =>
      find.descendant(of: find.byType(AppBar), matching: matching);

  double layerOpacity(WidgetTester tester, int index) => tester
      .widget<Opacity>(
        find.descendant(
          of: find.byKey(shellTitleLayerKey(index)),
          matching: find.byType(Opacity),
        ),
      )
      .opacity;

  /// 图层被画到离原位多远（`Transform.translate` 的平移量，矩阵第 13 个数）。
  double layerDx(WidgetTester tester, int index) => tester
      .widget<Transform>(
        find.descendant(
          of: find.byKey(shellTitleLayerKey(index)),
          matching: find.byType(Transform),
        ),
      )
      .transform
      .storage[12];

  /// 标题过渡的那一档（批 D 第 ① 项）：位移 10 → 18，透明度线性 → smoothstep。
  group('ShellTitle 的过渡幅度', () {
    test('位移幅度加到 18dp', () {
      expect(shellTitleShift, 18);
    });

    test('smoothstep：两头平、中间陡，中点仍然是一半', () {
      expect(shellTitleFade(0), closeTo(0, 1e-12));
      expect(shellTitleFade(1), closeTo(1, 1e-12));
      expect(shellTitleFade(0.5), closeTo(0.5, 1e-12), reason: '中点各半，不偏袒任何一侧');
      // 两头平（0 与 1 处导数为 0）：离开起点时旧标题还更实，逼近终点时新标题
      // 更早占主导 —— 线性时这两个数就是 0.25 与 0.75
      expect(shellTitleFade(0.25), lessThan(0.25), reason: '刚起步：旧标题还更实');
      expect(shellTitleFade(0.75), greaterThan(0.75), reason: '快到位：新标题更早占主导');

      // 单调 + 对称：拖回来是原样倒放，不存在"必须靠动画补回来"的状态
      var previous = -1.0;
      for (var step = 0; step <= 100; step += 1) {
        final t = step / 100;
        final value = shellTitleFade(t);
        expect(value, greaterThanOrEqualTo(previous - 1e-12), reason: 't=$t 倒退了');
        expect(value + shellTitleFade(1 - t), closeTo(1, 1e-12),
            reason: 't=$t 两层不透明度不再互补');
        previous = value;
      }

      // 越界的输入（浮点除法的尾巴）照样夹在 0 / 1 之间
      expect(shellTitleFade(-0.5), 0);
      expect(shellTitleFade(1.5), 1);
    });

    test('"两层都看得见"的区间比线性短 —— 这是"不糊"的量化口径', () {
      // 两层不透明度都落在 [0.2, 0.8] 的那一段有多长（越短越利落）。
      double bothVisibleSpan(double Function(double) fade) {
        var lo = -1.0;
        var hi = -1.0;
        for (var step = 0; step <= 1000; step += 1) {
          final t = step / 1000;
          final s = fade(t);
          if (s >= 0.2 && s <= 0.8) {
            if (lo < 0) lo = t;
            hi = t;
          }
        }
        return hi - lo;
      }

      expect(bothVisibleSpan((t) => t), closeTo(0.6, 0.01), reason: '线性时正好是 [0.2, 0.8]');
      expect(bothVisibleSpan(shellTitleFade), lessThan(0.45),
          reason: 'smoothstep 该把"两层都浓"的区间收掉一大截');
      expect(bothVisibleSpan(shellTitleFade), greaterThan(0.3),
          reason: '也不能收成硬切（那就退回"整数页号切换"了）');
    });
  });

  testWidgets('向左滑一下：从灵感页翻到项目页，底栏胶囊跟着过去', (tester) async {
    final app = await boot(tester);
    final cell = tester.getRect(find.byType(AppBottomNav)).width / 4;

    expect(find.text('未处理 0 条'), findsOneWidget, reason: '起点是灵感页');
    expect(pillLeft(tester), closeTo(0, 1));

    await swipe(tester, 1);

    expect(find.text('项目   1'), findsOneWidget, reason: '滑一下应当到项目页');
    expect(pillLeft(tester), closeTo(cell, 1), reason: '胶囊要跟到第 1 格');
    expect(app.prefs.lastTabIndex, 1, reason: '滑过去的页签同样要记住');
  });

  testWidgets('连续滑两下到事件页，再往回滑一下', (tester) async {
    await boot(tester);
    final cell = tester.getRect(find.byType(AppBottomNav)).width / 4;

    await swipe(tester, 2);
    expect(find.text('事件   1'), findsOneWidget);
    expect(pillLeft(tester), closeTo(cell * 2, 1));

    await swipe(tester, -1);
    expect(find.text('项目   1'), findsOneWidget);
    expect(pillLeft(tester), closeTo(cell, 1));
  });

  testWidgets('滑到「更多」页：标题栏与速记按钮跟着换', (tester) async {
    await boot(tester);

    await swipe(tester, 3);

    expect(find.text('主题与背景'), findsOneWidget, reason: '更多页的内容出现了');
    // 这条原来写的是 `inTitle(find.text('关于'))`（`ShellTitle` 的子树）—— 而
    // `关于` 挂在 `AppBar` 的 **actions** 槽上，与 `title` 槽（`ShellTitle`）是并列关系，
    // 不是后代，所以那个写法恒为 0 命中。改成限定在 `AppBar` 整条里找。
    //
    // 为什么要限定子树：更多页正文里也有一个小节标题叫「关于」
    // （`lib/ui/more/more_tab.dart` 的 `SectionHeader('关于')`），全树找会把它一起算进来。
    // 它此刻落在 `ListView` 视口之外、没被构建，所以全树找"看起来"也能过 ——
    // 但这依赖"列表恰好没建到那儿"，不是这条用例想钉的东西。
    expect(inAppBar(find.text('关于')), findsOneWidget,
        reason: '标题栏右侧只在更多页出现这个入口');
    // 连它的容器一起量：`TextButton` 只有一个，说明那一个 `关于` 就是它
    expect(inAppBar(find.byType(TextButton)), findsOneWidget);
    expect(find.text('速记'), findsOneWidget, reason: '非灵感页才有速记按钮');
  });

  testWidgets('速记按钮是与底栏滑块同一套的胶囊：高 48、宽 = 一格、实心强调色，且不压底栏（批 B 第 ③ 项）', (tester) async {
    await boot(tester);
    await swipe(tester, 1); // 到项目页：非灵感页才有速记按钮

    final nav = tester.getRect(find.byType(AppBottomNav));
    final pill = tester.getRect(find.byType(CapturePillButton));
    final indicator = tester.getRect(find.byKey(navIndicatorKey));

    expect(pill.height, closeTo(48, 0.01), reason: '与底栏滑块同高（48）');
    expect(
      pill.width,
      closeTo(nav.width / 4, 0.5),
      reason: '宽度 = 底栏一格 = (底栏可用宽 / 4)，与底栏同一套算法',
    );
    expect(
      pill.width,
      closeTo(indicator.width, 0.5),
      reason: '此刻与选中滑块等宽（同一格）',
    );
    expect(
      pill.bottom,
      lessThan(nav.top),
      reason: '速记按钮要抬在底栏上方，不能压住底栏',
    );

    // 形状与颜色：圆角 = 高度一半（24，与滑块共用 `_navRadius`）、
    // 底色 = **实心强调色**。以前两者同取 `secondaryContainer`（强调色 22% 透明度），
    // 实机反馈"速记按钮看着是透明的"：那层淡色浮在列表 / 卡片上几乎看不出来
    // （与页面底的对比度最低只有 1.94）。滑块在底栏内部、周围永远是那条实心底，
    // 所以它保持原样；这颗浮在内容上的入口改用 `primary` / `onPrimary`。
    final decoration = tester
        .widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(CapturePillButton),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .decoration as BoxDecoration;
    final scheme =
        Theme.of(tester.element(find.byType(CapturePillButton))).colorScheme;
    expect(decoration.borderRadius, BorderRadius.circular(24));
    expect(decoration.color, scheme.primary, reason: '实心强调色，不再跟滑块共用淡色');
    // 压在它上面的字必须读得清：`onPrimary` 与 `primary` 的对比度 ≥ 3:1
    final light = <double>[
      scheme.onPrimary.computeLuminance(),
      scheme.primary.computeLuminance(),
    ]..sort();
    expect(
      (light[1] + 0.05) / (light[0] + 0.05),
      greaterThanOrEqualTo(3.0),
      reason: '图标与「速记」两个字要压在实心强调色上',
    );
    final indicatorDecoration = tester
        .widget<Container>(find.byKey(navIndicatorKey))
        .decoration as BoxDecoration;
    expect(
      indicatorDecoration.color,
      scheme.secondaryContainer,
      reason: '底栏滑块保持原样（它坐在不透明的底栏里，不需要实心色）',
    );

    expect(
      find.descendant(
        of: find.byType(CapturePillButton),
        matching: find.text('速记'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('速记胶囊的出现要快、且不中途回弹（实机反馈"出现得太慢"）', (tester) async {
    await boot(tester);
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );

    // 每 20ms 量一次高度：进场途中**任何一帧都不许矮过头**。
    // 挂在 Scaffold 的 FAB 槽位时它自带 250ms + 一次旋转（对胶囊就是纵向压扁），
    // 实测高度会从 48 → 0.7 → 弹回 48，既慢又抖。
    final heights = <double>[];
    for (var i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 20));
      heights.add(tester.getRect(find.byType(CapturePillButton)).height);
    }
    expect(
      heights.first,
      greaterThan(24),
      reason: '第一帧就该有实体（从 0 缩起来的"慢热"就是这次要修的）',
    );
    for (final h in heights) {
      expect(h, greaterThan(24), reason: '进场途中不该出现"压扁"的帧：$heights');
    }
    expect(heights.last, closeTo(CapturePillButton.height, 0.5), reason: '160ms 内落位');

    // 收尾（把动画跑完再退，免得测试框架说还有 ticker）
    await tester.pumpAndSettle();
  });

  testWidgets('速记胶囊距底栏顶边 16：body 底边已在底栏之上，别再减一遍底栏高度（实机反馈"位置有点高"）', (tester) async {
    await boot(tester);
    await swipe(tester, 1); // 到项目页：非灵感页才有速记按钮

    final nav = tester.getRect(find.byType(AppBottomNav));
    final pill = tester.getRect(find.byType(CapturePillButton));

    // 原来这里写的是 `_navHeight + _navBottomPadding + 空隙` —— 那套算法来自它还挂在
    // Scaffold 的 FAB 槽位时的实测。改成自己摆之后，**body 的底边本来就在底栏顶边之上**，
    // 于是再多加 48 + 18 就把胶囊抬高了整整一条底栏：实测空隙 82。
    expect(
      nav.top - pill.bottom,
      closeTo(16, 0.5),
      reason: '空隙应当只有那 16dp（`_pillMarginAboveNav`），不是 48 + 18 + 16',
    );
    expect(pill.bottom, lessThan(nav.top), reason: '仍然要抬在底栏上方，不能压住底栏');
  });

  testWidgets('速记胶囊的**退场**也是动画：切回灵感页时逐帧淡出、不是啪地没了（实机反馈）', (tester) async {
    await boot(tester);
    await swipe(tester, 1); // 到项目页，胶囊进场并停稳
    await tester.pumpAndSettle();

    Animation<double> pillOpacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(CapturePillButton),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity;

    Animation<double> pillScale() => tester
        .widget<ScaleTransition>(
          find
              .ancestor(
                of: find.byType(CapturePillButton),
                matching: find.byType(ScaleTransition),
              )
              .first,
        )
        .scale;

    expect(pillOpacity().value, closeTo(1, 0.01), reason: '先确认它在项目页是显示着的');

    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('灵感')),
    );

    // 逐帧采样：必须经过**中间值**。原来是直接把动画值设成 0（一帧之内就没了），
    // 所以这里只要出现一个"既不是 1 也不是 0"的采样就证明退场有过程。
    final opacities = <double>[];
    for (var i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      opacities.add(pillOpacity().value);
    }

    expect(
      opacities.any((v) => v > 0.02 && v < 0.98),
      isTrue,
      reason: '退场途中要有中间态；一帧从 1 到 0 就是"没有动画"：$opacities',
    );
    // 单调下降：不能回弹
    for (var i = 1; i < opacities.length; i += 1) {
      expect(
        opacities[i],
        lessThanOrEqualTo(opacities[i - 1] + 1e-6),
        reason: '淡出途中不该变大：$opacities',
      );
    }

    await tester.pumpAndSettle();
    expect(pillOpacity().value, closeTo(0, 0.01), reason: '最终要收干净');
    expect(pillScale().value, lessThan(1), reason: '缩回起始比例，与进场对称');
  });

  testWidgets('从最后一页点回灵感页：速记胶囊只该隐藏一次，不能闪（实机反馈"会闪两下"）', (tester) async {
    await boot(tester);
    // 走到最后一页（更多）—— 这样点回灵感页要跨过中间两页
    await swipe(tester, 3);
    await tester.pumpAndSettle();

    Animation<double> pillOpacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(CapturePillButton),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity;

    expect(pillOpacity().value, closeTo(1, 0.01), reason: '更多页是显示着的');

    // 点底栏的「灵感」
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('灵感')),
    );

    // 逐帧记录不透明度：只允许"单调降到 0"。
    // 点按会立刻把 `_index` 设成 0（胶囊隐藏），但 PageView 滑过中间页时会依次报
    // 2、1，`onPageChanged` 又把 `_index` 改回非 0 —— 于是胶囊又冒出来：
    // 实测会出现 1 → 0 → 0.8(又出现) → 0 这种"闪"，单调性正好能抓住它。
    final samples = <double>[];
    for (var i = 0; i < 14; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      samples.add(pillOpacity().value);
    }

    for (var i = 1; i < samples.length; i += 1) {
      expect(
        samples[i],
        lessThanOrEqualTo(samples[i - 1] + 1e-6),
        reason: '胶囊不该在退场途中又变大（那就是"闪"）：$samples',
      );
    }
    expect(samples.last, closeTo(0, 0.01), reason: '最终要收干净');
    await tester.pumpAndSettle();
  });

  testWidgets('键盘弹出时速记胶囊收起来（实机反馈"开输入框时它飞到顶上"）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();

    double opacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(CapturePillButton),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    double gapToNav() {
      final nav = tester.getRect(find.byType(AppBottomNav));
      final pill = tester.getRect(find.byType(CapturePillButton));
      return nav.top - pill.bottom;
    }

    expect(opacity(), closeTo(1, 0.01), reason: '先在项目页显示着');
    expect(gapToNav(), closeTo(16, 0.5), reason: '距底栏顶边 16');

    // 键盘弹出：**它必须收起来**。
    // 为什么不做成"跟着键盘上移"：胶囊挂在 body 那个 Stack 的底边上，而键盘弹出时
    // `Scaffold` 会压缩 body、底栏不动 —— 两者裂开一整个键盘的高度，胶囊被顶到上半屏。
    // 试过三种补正公式都在"有/无键盘"之间来回翻，根因是参照物本身在动。
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await tester.pumpAndSettle();
    expect(
      opacity(),
      closeTo(0, 0.01),
      reason: '打字时这个入口不该占着屏幕，更不该飞到上半屏',
    );

    // 键盘收起：回来，位置照旧
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(opacity(), closeTo(1, 0.01), reason: '收起键盘后要回来');
    expect(gapToNav(), closeTo(16, 0.5), reason: '位置不变');
  });

  testWidgets('键盘弹出时内容区不被截断：底边仍等于底栏顶边（实机反馈"下半部被截断"）',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();

    double contentBottom() => tester.getRect(find.byType(PageView)).bottom;
    final nav = tester.getRect(find.byType(AppBottomNav));

    // **内容区底边必须就是底栏顶边** —— 中间不许留空档。
    //
    // 这条是 2026-09-28 补的：上一版曾经在 body 底部给速记胶囊"留一条空档"，
    // 结果内容被顶到半空、卡片里最后一条被齐刷刷裁掉一半，用户看到的是
    // "下半部被截断"（而且**不随键盘移动**，所以与键盘无关）。
    // 我当时只断言了"键盘前后底边一致"—— 量了个稳定但错的值，白改一遍。
    expect(
      contentBottom(),
      closeTo(nav.top, 0.5),
      reason: '内容区与底栏之间不许有空档：留白会把卡片最后一条裁掉一半',
    );
    final withoutKeyboard = contentBottom();

    // 键盘弹出：内容**不许**被压缩上去 —— 那会在内容与底栏之间裂开一整个
    // 键盘高的空档（实测 360×780 + 键盘 300：内容到 y=400、底栏还在 714，空档 314dp）
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    await tester.pumpAndSettle();

    expect(
      contentBottom(),
      closeTo(withoutKeyboard, 0.5),
      reason: '键盘弹出不该改变内容区底边 —— 截点跟着键盘走、底栏不动，就会"下半部被截断"',
    );
    expect(
      tester.getRect(find.byType(AppBottomNav)).top,
      closeTo(nav.top, 0.5),
      reason: '底栏位置也不该被键盘改动',
    );
  });

  testWidgets('窄屏 + 1.6 倍字体：一格放不下就只画图标，但 tooltip 与语义标签仍是「速记」', (tester) async {
    // 360 × 780 逻辑像素（常见手机）；1.6 倍字体下一格只有 (360 − 40) / 4 = 80dp
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(CapturePillButton),
        matching: find.text('速记'),
      ),
      findsNothing,
      reason: '一格宽度放不下「图标 + 速记」，这时只画图标',
    );
    expect(
      find.descendant(
        of: find.byType(CapturePillButton),
        matching: find.byIcon(Icons.bolt),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('速记'), findsOneWidget, reason: 'tooltip 不能跟着文字一起消失');

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('速记'),
      findsOneWidget,
      reason: '只画图标时，语义标签是唯一能念出「速记」的地方',
    );
    semantics.dispose();

    // 点击行为不变：切到灵感页并把光标放进速记框
    await tester.tap(find.byType(CapturePillButton));
    await tester.pumpAndSettle();
    expect(find.text('未处理 0 条'), findsOneWidget, reason: '点它应当回到灵感页');
    // `focusCapture` 里还挂着一个 450ms 的"再要一次键盘"（HyperOS 实测需要），
    // 让它跑完再收尾 —— 否则测试框架会判"还有 Timer 没结束"
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('点底栏切页与滑动切页结果一致', (tester) async {
    final app = await boot(tester);
    final cell = tester.getRect(find.byType(AppBottomNav)).width / 4;

    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    expect(find.text('事件   1'), findsOneWidget);
    expect(app.prefs.lastTabIndex, 2);
    expect(pillLeft(tester), closeTo(cell * 2, 1));
  });

  testWidgets('拖动切页时标题也跟着走：交叉淡入淡出 + 轻微横移，拖回来原样还原', (tester) async {
    await boot(tester);
    final width = tester.getRect(find.byType(PageView)).width;

    // 静止：只有一个标题，不留动画痕迹（图层 key 也不该存在）
    expect(inTitle(find.text('灵感')), findsOneWidget);
    expect(inTitle(find.byType(Opacity)), findsNothing);
    expect(find.byKey(shellTitleLayerKey(0)), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(Offset(-width * 0.4, 0));
    await tester.pump();

    // 过渡中：两页各一层
    expect(inTitle(find.byType(Opacity)), findsNWidgets(2));
    expect(inTitle(find.text('项目   1')), findsOneWidget,
        reason: '第 1 页那一层的数量要按项目页自己的口径算');
    expect(inTitle(find.text('灵感')), findsOneWidget, reason: '旧标题还在淡出');

    final opacity = <double>[layerOpacity(tester, 0), layerOpacity(tester, 1)];
    final dx = <double>[layerDx(tester, 0), layerDx(tester, 1)];
    expect(opacity[0] + opacity[1], closeTo(1, 1e-9), reason: '两层不透明度互补');
    expect(opacity[1], greaterThan(0.05));
    expect(opacity[1], lessThan(0.95), reason: '手指停在一半，标题也该停在一半');
    expect(dx[0], lessThan(0), reason: '往后翻：旧标题朝左淡出');
    expect(dx[1], greaterThan(0), reason: '往后翻：新标题自右淡入');
    // 位移与不透明度由**同一个数**算出 —— 这正是"跟手、可回退"的根据
    expect(dx[0], closeTo(-shellTitleShift * opacity[1], 1e-9));
    expect(dx[1], closeTo(shellTitleShift * opacity[0], 1e-9));
    expect(dx[0], greaterThanOrEqualTo(-shellTitleShift - 1e-9));
    expect(dx[1], lessThanOrEqualTo(shellTitleShift + 1e-9));
    // 两层位移之差恒等于位移幅度（10 → 18），与手指停在哪儿无关
    expect(dx[1] - dx[0], closeTo(shellTitleShift, 1e-9));

    // 拖回起点：标题**原样**回来（不是靠动画补回来的）
    await gesture.moveBy(Offset(width * 0.4, 0));
    await tester.pump();
    expect(inTitle(find.text('灵感')), findsOneWidget);
    expect(inTitle(find.byType(Opacity)), findsNothing);
    expect(find.byKey(shellTitleLayerKey(1)), findsNothing);

    // 再拖到同一个位置：读数与第一次逐位一致（只看当前值、不看历史）
    await gesture.moveBy(Offset(-width * 0.4, 0));
    await tester.pump();
    expect(layerOpacity(tester, 0), closeTo(opacity[0], 1e-9));
    expect(layerOpacity(tester, 1), closeTo(opacity[1], 1e-9));
    expect(layerDx(tester, 0), closeTo(dx[0], 1e-9));
    expect(layerDx(tester, 1), closeTo(dx[1], 1e-9));

    await gesture.up();
    await tester.pumpAndSettle();
    // 松手落位后同样不留图层
    expect(inTitle(find.byType(Opacity)), findsNothing);
  });

  testWidgets('标题过渡用的是 smoothstep：同样一段拖动，起点附近涨得慢、中段涨得快（批 D 第 ① 项）', (tester) async {
    await boot(tester);
    final width = tester.getRect(find.byType(PageView)).width;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );

    // 第一段：从 0 出发拖 1/4 屏 —— smoothstep 在起点附近平，浓度涨得慢
    await gesture.moveBy(Offset(-width * 0.25, 0));
    await tester.pump();
    final firstLeg = layerOpacity(tester, 1);

    // 第二段：再拖 3/8 屏，落进斜率最大的中段 —— 浓度涨得快
    await gesture.moveBy(Offset(-width * 0.375, 0));
    await tester.pump();
    final secondLeg = layerOpacity(tester, 1) - firstLeg;

    // 换算成"每 dp 拖动涨多少浓度"：线性实现两段一样大（都是 1/屏宽），
    // smoothstep 的第二段该明显更大 —— 这正是"不糊"的来源。
    // （第一段会被手势的 touch slop 吃掉一点，所以只用比例，不写死数值。）
    expect(secondLeg / 0.375, greaterThan(firstLeg / 0.25 * 1.3),
        reason: '中段没有比起点附近陡，说明用的还是线性那一版');
    expect(firstLeg, greaterThan(0.05), reason: '起点附近也不能压成 0（那就是硬切）');
    expect(secondLeg, greaterThan(0.05));
    expect(layerOpacity(tester, 0) + layerOpacity(tester, 1), closeTo(1, 1e-9));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(inTitle(find.byType(Opacity)), findsNothing, reason: '落位后收干净');
  });

  testWidgets('点底栏切页时标题也在过渡（与翻页同一条时间线）', (tester) async {
    await boot(tester);

    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pump(); // 起帧：ticker 从这一帧开始计时
    await tester.pump(const Duration(milliseconds: 110)); // 220ms 的一半
    expect(inTitle(find.byType(Opacity)), findsNWidgets(2), reason: '点按也该有过渡，不是直接换');
    expect(inTitle(find.text('灵感')), findsOneWidget);
    expect(inTitle(find.text('项目   1')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(inTitle(find.text('项目   1')), findsOneWidget);
    expect(inTitle(find.byType(Opacity)), findsNothing, reason: '落位后收干净');
  });

  /// 点底栏某一项，并在位移沿途逐帧采样指示器（`animateToPage` 是 220ms）。
  Future<List<Rect>> tapAndSample(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text(label)),
    );
    final samples = <Rect>[];
    for (var i = 0; i < 34; i += 1) {
      await tester.pump(const Duration(milliseconds: 8));
      samples.add(tester.getRect(find.byKey(navIndicatorKey)));
    }
    await tester.pumpAndSettle();
    return samples;
  }

  testWidgets('点按切换：指示器过冲更明显（一格行程的 6%~8%）再吸回，落位与页面一致', (tester) async {
    await boot(tester);
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;

    // 灵感 → 事件：跨两格，且目标不是最右那一格（贴边时过冲会被夹在栏内）。
    // 过冲是**按相邻两格之间那一段**算的（几何就是这么喂的），
    // 所以量纲是"一格行程"，与纯函数那条用例同口径。
    final samples = await tapAndSample(tester, '事件');
    final target = bar.left + cell * 3;
    final peak = samples.map((rect) => rect.right).reduce(math.max);

    expect(peak, greaterThan(target + 1),
        reason: '点按应当有过冲；"感觉不到惯性"就是少了这一下');
    // 批 D 第 ② 项：y1 1.35 → 1.5，峰值 4.1% → 8%，上界跟着抬到 8%
    expect(peak, lessThanOrEqualTo(target + cell * 0.085 + 0.5),
        reason: '过冲不许超过一格行程的 8%，否则看着像没对准');
    expect(peak, greaterThanOrEqualTo(target + cell * 0.06 - 0.5),
        reason: '过冲也不能小到看不出来（原来那一档只有 4.1%）');

    // 落位：页面、底栏、标题三者一致（结束值相同，过冲不留错位）
    expect(find.text('事件   1'), findsOneWidget);
    expect(pillLeft(tester), closeTo(cell * 2, 1));
    expect(tester.getRect(find.byKey(navIndicatorKey)).right, closeTo(target, 1));
  });

  testWidgets('点按切到最右那一格：过冲被夹住，胶囊不顶出导航条', (tester) async {
    await boot(tester);
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;

    final samples = await tapAndSample(tester, '更多');
    for (final rect in samples) {
      expect(rect.left, greaterThanOrEqualTo(bar.left - 0.01), reason: '顶出左端');
      expect(rect.right, lessThanOrEqualTo(bar.right + 0.01), reason: '顶出右端');
    }
    expect(pillLeft(tester), closeTo(cell * 3, 1), reason: '照样要正好停在最后一格');
  });

  testWidgets('连点两次：后一次点按的过冲不被前一次的收尾抹掉', (tester) async {
    await boot(tester);
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;

    // 第一次还没跑完就点第二次：前一次的 future 会因为被接管而立刻完成，
    // 收尾时必须认得出"这不是我这一程"，否则后一次就悄悄变成没有过冲的普通位移
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('事件')),
    );
    await tester.pump();

    final target = bar.left + cell * 3;
    var peak = 0.0;
    for (var i = 0; i < 34; i += 1) {
      await tester.pump(const Duration(milliseconds: 8));
      peak = math.max(peak, tester.getRect(find.byKey(navIndicatorKey)).right);
    }
    await tester.pumpAndSettle();
    expect(peak, greaterThan(target + 1), reason: '后一次点按照样应当有过冲');
    expect(pillLeft(tester), closeTo(cell * 2, 1), reason: '最终停在「事件」那一格');
  });

  testWidgets('关闭动画时：点按不过冲、拉伸回到原值，标题直接切换不做位移', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.ws.createProject(title: '一个项目');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();

    // ---- 标题：不做位移、不留两层，直接切到离得最近的那一页
    final pageWidth = tester.getRect(find.byType(PageView)).width;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(Offset(-pageWidth * 0.7, 0));
    await tester.pump();
    expect(inTitle(find.byType(Transform)), findsNothing, reason: '关闭动画时不做位移');
    expect(inTitle(find.byType(Opacity)), findsNothing, reason: '也不做交叉淡入淡出');
    expect(inTitle(find.text('项目   1')), findsOneWidget,
        reason: '直接切到离得最近的那一页（此刻已经过半）');
    await gesture.up();
    await tester.pumpAndSettle();

    // ---- 底栏：点按不过冲、拉伸回到原值（此刻在项目页，点「事件」走一格）
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;
    final samples = await tapAndSample(tester, '事件');
    final target = bar.left + cell * 3;

    expect(samples.map((rect) => rect.right).reduce(math.max),
        lessThanOrEqualTo(target + 0.01),
        reason: '关闭动画时点按不该有过冲');
    final peakWidth =
        samples.map((rect) => rect.width).reduce(math.max) - cell;
    expect(peakWidth, greaterThan(3), reason: '退化不是"完全不拉伸"，只是回到原来那一档');
    expect(peakWidth, lessThanOrEqualTo(navStretchMaxReduced + 0.01),
        reason: '拉伸回到原上限 12');
  });

  testWidgets('切过去再切回来不丢状态（保活）', (tester) async {
    final app = await boot(tester);

    // 在灵感页写一半
    await tester.enterText(find.byType(TextField).first, '写到一半的灵感');
    await tester.pumpAndSettle();

    await swipe(tester, 1);
    await swipe(tester, -1);

    expect(
      find.text('写到一半的灵感'),
      findsOneWidget,
      reason: '滑走再滑回来，输入框里的内容不该没',
    );
    expect(app.ws.inspirationInbox, isEmpty, reason: '没点「记下」就不该落库');
  });

  testWidgets('标题栏的项目数不随收起 / 展开变化（只数最外层、不含已归档）', (tester) async {
    final app = await boot(tester); // boot 里已经有一条「一个项目」

    // 根层再加：一个分类（下面挂两个目标）+ 一个独立目标
    final category = app.ws.createProject(title: '分类一');
    app.run(() => app.ws.createProject(title: '目标甲', parentId: category.id));
    app.run(() => app.ws.createProject(title: '目标乙', parentId: category.id));
    app.run(() => app.ws.createProject(title: '独立目标'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(
      find.text('项目   3'),
      findsOneWidget,
      reason: '只数最外层：一个项目 + 分类一 + 独立目标；分类里面那两个目标不算',
    );

    // 收起 / 展开分类一：数字都不该变（原来取的是"画出来的行数"，一收就变小）。
    // 展开 / 收起走行尾的 ⋮ 菜单（行首那根色条不再是展开控件）。
    await tester.tap(
      find.descendant(
        of: find.byKey(projectRowKey(category.id)),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('收起下级'));
    await tester.pumpAndSettle();
    expect(find.text('项目   3'), findsOneWidget, reason: '收起之后数字不变');

    // 已归档的根项目不计入
    app.run(() => app.ws.setProjectArchived(category.id, true));
    await tester.pumpAndSettle();
    expect(find.text('项目   2'), findsOneWidget, reason: '归档的那条不再计入');
  });
}
