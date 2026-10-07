import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/inspiration/empty_box_lines.dart';

import 'scroll_finders.dart';

/// 灵感页的新接线：
///   · 点一条 → 动作面板里有「编辑内容」，改完落盘；
///   · 长按任一条进入多选，批量分配 / 丢弃；
///   · 项目详情页的待处理灵感可以直接点进合并编辑器（不必绕回灵感页）。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_insp_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  testWidgets('点灵感 → 编辑内容 → 改完真的落盘', (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('原来的灵感内容'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('原来的灵感内容'));
    await tester.pumpAndSettle();
    expect(find.text('编辑内容'), findsOneWidget, reason: '动作面板里要有编辑入口');

    await tester.tap(find.text('编辑内容'));
    await tester.pumpAndSettle();

    // 编辑态是**页内直编**：此时有两个输入框 —— 上面的速记框（空）和
    // 这条灵感的编辑行（预填原值），要改的是后者。
    expect(find.byType(TextField), findsNWidgets(2));
    final field = find.byType(TextField).last;
    await tester.enterText(field, '改过之后的灵感内容');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      app.ws.liveInspirations.single.text,
      '改过之后的灵感内容',
      reason: '改完要真的写进数据',
    );
  });

  testWidgets('长按进入多选，批量分配一次改完所有选中项', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标项目');
    app.run(() => app.ws.captureInspiration('灵感甲'));
    app.run(() => app.ws.captureInspiration('灵感乙'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 长按第一条 → 进入多选（"已选 n 条"在多选条和标题行各出现一次）
    await tester.longPress(find.text('灵感甲'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsWidgets);
    // 多选模式下的勾选记号是**圆形**的（2026-09-28 实机反馈：动作条与条目都用
    // 胶囊 / 圆形元素）：两条里选中的那个是实心圆、没选的是空心圆，
    // 动作条里的「全选」默认也是空心圆
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
    expect(find.byIcon(Icons.check_circle), findsOneWidget, reason: '选中的那条是实心圆');
    expect(find.byType(Checkbox), findsNothing, reason: '方形勾选框已经换掉了');

    // 再点第二条 → 选中两条
    await tester.tap(find.text('灵感乙'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsWidgets);

    // 批量分配
    await tester.tap(find.byIcon(Icons.drive_file_move_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标项目').last);
    await tester.pumpAndSettle();

    for (final inspiration in app.ws.liveInspirations) {
      expect(inspiration.projectId, project.id, reason: '两条都该被分配到目标项目');
    }
  });

  testWidgets('多选批量丢弃：一次丢两条，且退出多选', (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('待丢甲'));
    app.run(() => app.ws.captureInspiration('待丢乙'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('待丢甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('待丢乙'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pumpAndSettle();

    expect(app.ws.inspirationInbox, isEmpty, reason: '两条都该被丢弃');
    expect(app.ws.archiveZone.discardedInspirations.length, 2);
    expect(find.text('已选 1 条'), findsNothing, reason: '批量动作完要退出多选');
  });

  testWidgets('多选里有「全选」：一次选中当前可见的全部', (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('甲'));
    app.run(() => app.ws.captureInspiration('乙'));
    app.run(() => app.ws.captureInspiration('丙'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 长按进多选（页头那枚「多选」按钮已按实机反馈拿掉）
    await tester.longPress(find.text('甲'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsWidgets, reason: '进多选默认选中第一条');

    // 动作条里的「全选」是那个圆形记号（tooltip 说得出它现在是什么）
    await tester.tap(find.byTooltip('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsWidgets, reason: '全选应当把可见的都选上');

    // 再点一次 = 取消全选
    await tester.tap(find.byTooltip('取消全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsWidgets);
  });

  testWidgets('页头不再有「多选」入口，也没有 ⋮ 里的「多选…」—— 只剩长按这一条路',
      (tester) async {
    final app = await boot();
    app.run(() => app.ws.captureInspiration('一条灵感'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    expect(
      find.text('多选'),
      findsNothing,
      reason: '实机反馈：把"多选"这个入口拿掉（功能保留，长按进得去）',
    );

    // ⋮ 的面板里也没有那一项
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('多选…'), findsNothing);
    expect(find.text('编辑内容'), findsOneWidget, reason: '面板本身还在，只是少了多选与标签两项');
    expect(find.text('标签…'), findsNothing, reason: '标签系统整批移除');

    // 长按照样进得去
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('一条灵感'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsWidgets, reason: '长按这条入口一个字没改');
  });

  testWidgets('项目详情页的待处理灵感可以直接点进合并编辑器', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目甲');
    app.run(() => app.ws.captureInspiration('这条灵感要合并', projectId: project.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目甲').first);
    await tester.pumpAndSettle();

    // 灵感区在页面靠下（前面还有标识色等字段），`ListView` 是懒构建的，
    // 所以"待处理灵感"这块**在滚动到之前根本没被建出来** —— 必须先滚再看。
    await tester.scrollUntilVisible(
      find.text('这条灵感要合并'),
      120,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('待处理灵感 1'), findsOneWidget);
    await tester.ensureVisible(find.text('这条灵感要合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这条灵感要合并'));
    await tester.pumpAndSettle();

    // 进了合并编辑器：标题带项目名，编辑框里**就是当前的「如何解决」**
    expect(find.textContaining('合并进「项目甲」'), findsOneWidget);
    expect(find.text('如何解决 · 可编辑'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first,
    );
    expect(field.controller!.text, isEmpty, reason: '项目还没写正文 → 编辑框是空的');
  });

  testWidgets('合并选择一：手改正文 → 保存写回「实现计划」，灵感进归档区', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '项目乙');
    app.run(() => app.ws.updateProject(project.id, implementation: '手写的计划'));
    app.run(() => app.ws.captureInspiration('灵感原文', projectId: project.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目乙').first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('灵感原文'),
      120,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('灵感原文'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('灵感原文'));
    await tester.pumpAndSettle();

    // 编辑框预填当前正文，照着灵感改一版再保存
    final field = find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first;
    await tester.enterText(field, '改好的计划：灵感原文');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.implementation, '改好的计划：灵感原文');
    expect(reloaded.items, isEmpty, reason: '走正文这一条就不动清单');
    expect(app.ws.inspirationInbox, isEmpty);
    expect(app.ws.archiveZone.mergedInspirations.length, 1);
    // 回到详情页：正文在「实现 · 文本」那一侧，默认给的是「清单」，先切过去
    await tester.tap(find.text('文本'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('改好的计划：灵感原文'),
      findsOneWidget,
      reason: '回到详情页，文本模式里就是刚保存的那段',
    );
  });

  testWidgets('多选合并：一次进编辑器，追加原文把两条按顺序各占一行接进正文（Q37）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标项目');
    app.run(() => app.ws.updateProject(project.id, implementation: '已有的正文'));
    app.run(() => app.ws.captureInspiration('灵感甲', projectId: project.id));
    app.run(() => app.ws.captureInspiration('灵感乙', projectId: project.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 合并顺序 = 列表当前顺序（创建时间倒序，也就是用户看到的从上到下）
    final order = app.ws.inspirationInbox.map((i) => i.text).toList(growable: false);
    expect(order.length, 2);
    expect(
      tester.getTopLeft(find.text(order[0])).dy,
      lessThan(tester.getTopLeft(find.text(order[1])).dy),
      reason: '列表上第一条就在第二条上面（顺序按它算）',
    );

    await tester.longPress(find.text(order[0]));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order[1]));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsWidgets);

    // 多选动作条上的「合并…」（与其它动作同一套胶囊图标按钮）
    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();
    // **不再问落点**（2026-09-28 实机反馈：已经分配了项目的灵感直接并进对应项目）
    // —— 两条都归「目标项目」，所以直接进它的编辑器
    expect(find.text('合并到哪个项目'), findsNothing, reason: '有唯一归属时不问落点');

    // 编辑器里要能看出"这次并的是哪几条"：多条按顺序列出来、默认展开
    expect(find.textContaining('合并进「目标项目」'), findsOneWidget);
    expect(find.text('灵感原文 · 参考 2 条'), findsOneWidget);
    expect(find.text(order[0]), findsOneWidget);
    expect(find.text(order[1]), findsOneWidget);

    await tester.tap(find.text('追加原文'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      app.ws.findProject(project.id)!.implementation,
      '已有的正文\n${order[0]}\n${order[1]}',
      reason: '多条原文按顺序各占一行接到正文末尾',
    );
    expect(app.ws.inspirationInbox, isEmpty);
    expect(
      app.ws.archiveZone.mergedInspirations.length,
      2,
      reason: '两条都要能在归档区「已合并」找回',
    );
    expect(find.textContaining('已把 2 条灵感并进「目标项目」'), findsOneWidget);
    expect(find.text('已选 1 条'), findsNothing, reason: '合并完要退出多选');
  });

  testWidgets('多选合并「作为清单条目」：清单多出两条，顺序与列表一致（Q37）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标项目');
    app.run(() => app.ws.captureInspiration('灵感甲', projectId: project.id));
    app.run(() => app.ws.captureInspiration('灵感乙', projectId: project.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    final order = app.ws.inspirationInbox.map((i) => i.text).toList(growable: false);
    await tester.longPress(find.text(order[0]));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order[1]));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();
    // 两条都归「目标项目」→ 不问落点，直接进编辑器
    expect(find.text('合并到哪个项目'), findsNothing);

    await tester.tap(find.text('作为清单条目'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.items.map((i) => i.text), order, reason: '一条灵感一条，顺序与列表一致');
    expect(reloaded.implementation, isEmpty, reason: '这个落点不碰正文');
    expect(app.ws.inspirationInbox, isEmpty);
    expect(app.ws.archiveZone.mergedInspirations.length, 2);
    expect(find.textContaining('已把 2 条灵感追加到「目标项目」的清单'), findsOneWidget);
  });

  testWidgets('合并落在分类上时回退到"问一次"：分类点不动，只给一句「分类不装灵感」（Q37 / Q2）',
      (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    app.ws.createProject(title: '发布 v1', parentId: category.id);
    app.run(() => app.ws.captureInspiration('灵感甲', projectId: category.id));
    app.run(() => app.ws.captureInspiration('灵感乙', projectId: category.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 只选了 1 条也能用「合并…」（行为等同单条合并）
    await tester.longPress(find.text('灵感甲'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();

    // 它们挂在**分类**上，而分类不是落点（Q2）→ 没有可推断的目标，
    // 于是退回"问一次落点"，让用户自己挑一个真目标
    expect(find.text('合并到哪个项目'), findsOneWidget, reason: '分类不能当落点，只能问');

    // 分类行明说"不装灵感"：点它只给提示，不往下走。
    // `.last` 是因为页面上还有两条灵感的副标题也写着「工作」（它们就挂在这个分类上），
    // 而选择器是后叠加出来的那一层。
    expect(find.text('分类，这里不装灵感'), findsOneWidget);
    await tester.tap(find.text('工作').last);
    await tester.pumpAndSettle();

    expect(find.text('分类不装灵感，请选一个目标或先建一个目标'), findsOneWidget);
    expect(find.textContaining('合并进「'), findsNothing, reason: '被拦下就不该进编辑器');
    expect(app.ws.inspirationInbox.length, 2, reason: '一条都不许被合掉');
    expect(app.ws.archiveZone.mergedInspirations, isEmpty);

    // 选目标才继续（选择器那一行只写项目自己的名字）
    await tester.tap(find.text('发布 v1').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('合并进「发布 v1」'), findsOneWidget);
  });

  testWidgets('合并自动分组流水作业：跨两个项目的灵感各组并回自己那个项目', (tester) async {
    final app = await boot();
    final alpha = app.ws.createProject(title: '项目甲');
    final beta = app.ws.createProject(title: '项目乙');
    // 每个项目一条，避免"同一组两条"带来的顺序问题
    app.run(() => app.ws.captureInspiration('甲的那条', projectId: alpha.id));
    app.run(() => app.ws.captureInspiration('乙的那条', projectId: beta.id));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('甲的那条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙的那条'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsWidgets);

    await tester.tap(find.byIcon(Icons.merge_type));
    await tester.pumpAndSettle();

    // 分成两组 → 不问落点，直接进第一组的编辑器；一组做完返回后自动进下一组
    expect(find.text('合并到哪个项目'), findsNothing, reason: '两组都有归属，不需要再问');
    expect(find.text('作为清单条目'), findsOneWidget, reason: '第一组的编辑器');

    // 流水做完两组：每一组都用「作为清单条目」这个落点
    await tester.tap(find.text('作为清单条目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('作为清单条目'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(alpha.id)!.items.map((i) => i.text), <String>['甲的那条']);
    expect(app.ws.findProject(beta.id)!.items.map((i) => i.text), <String>['乙的那条']);
    expect(app.ws.inspirationInbox, isEmpty, reason: '两条都被合掉了');
    expect(app.ws.archiveZone.mergedInspirations.length, 2);
    expect(find.text('已选 2 条'), findsNothing, reason: '流水做完要退出多选');
  });

  testWidgets('写下来的时候就选好项目：选完「记下」直接就是已分配', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标项目');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 书写区的归属按钮默认「未分配」
    expect(find.text('未分配'), findsOneWidget);

    await tester.tap(find.text('未分配'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标项目').last);
    await tester.pumpAndSettle();
    expect(find.text('目标项目'), findsOneWidget, reason: '选完按钮上要显示项目名');

    await tester.enterText(find.byType(TextField).first, '写下就归好类的灵感');
    await tester.tap(find.text('记下'));
    await tester.pumpAndSettle();

    final captured = app.ws.liveInspirations.single;
    expect(captured.text, '写下就归好类的灵感');
    expect(captured.projectId, project.id, reason: '归属应当在书写时就定下来');
  });

  testWidgets('灵感条目下面那半行给**全名**「分类名 · 项目名」，三层一路写到根（2026-10-07 用户要求）',
      (tester) async {
    final app = await boot();
    final work = app.ws.createProject(title: '工作');
    final release = app.ws.createProject(title: '发布 v1', parentId: work.id);
    final frontend = app.ws.createProject(title: '前端', parentId: release.id);
    app.run(() => app.ws.captureInspiration('三级项目下的一条', projectId: frontend.id));
    app.run(() => app.ws.captureInspiration('二级项目下的一条', projectId: release.id));
    app.run(() => app.ws.captureInspiration('还没分配的一条'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 归属就写在这条灵感**下面那半行**：只写「前端」/「发布 v1」的话，
    // 两个分类下各有一个同名项目时分不出是哪一支
    expect(find.text('工作 · 发布 v1 · 前端'), findsOneWidget, reason: '三层一路写到根');
    expect(find.text('工作 · 发布 v1'), findsOneWidget);
    // 「未分配」在灵感页出现两次：书写区那个归属按钮一次、条目那半行一次
    // （2026-10-07 之前只有按钮那一处，所以老写法 `findsOneWidget` 现在会红）
    expect(
      find.text('未分配'),
      findsNWidgets(2),
      reason: '书写区按钮 + 没归属的那条灵感',
    );
    expect(
      find.text('前端'),
      findsNothing,
      reason: '这一行上不该再出现"只有自己的名字"的写法',
    );

    // 点这一行就是按这个项目筛（原来的动作不动），芯片上写同一份全名
    await tester.tap(find.text('工作 · 发布 v1 · 前端'));
    await tester.pumpAndSettle();
    expect(find.text('只看「工作 · 发布 v1 · 前端」'), findsOneWidget);
  });

  testWidgets('选择器那一行仍然只写项目自己的名字（层级靠缩进）', (tester) async {
    final app = await boot();
    final work = app.ws.createProject(title: '工作');
    app.ws.createProject(title: '发布 v1', parentId: work.id);

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未分配'));
    await tester.pumpAndSettle();

    expect(find.text('发布 v1'), findsOneWidget, reason: '弹窗里一次只挑一个，缩进够用');
    expect(
      find.text('工作 · 发布 v1'),
      findsNothing,
      reason: '全名只给灵感条目那半行（2026-10-07 试过给选择器，按用户口径撤回）',
    );
  });

  testWidgets('书写框更高了，且「记下」按钮不随归属标签长短移动', (tester) async {
    final app = await boot();
    const longName = '一个名字特别长的项目名称用来把标签撑到最宽';
    app.ws.createProject(title: longName);

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 三行起步（实机反馈"稍微拉长一点"）
    expect(tester.widget<TextField>(find.byType(TextField).first).minLines, 3);

    final before = tester.getRect(find.text('记下'));

    await tester.tap(find.text('未分配'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(longName).last);
    await tester.pumpAndSettle();
    expect(find.text(longName), findsOneWidget, reason: '归属按钮上要显示选中的项目');

    final after = tester.getRect(find.text('记下'));
    expect(after.left, closeTo(before.left, 0.01),
        reason: '「记下」的位置不该跟着左侧标签跑');
    expect(after.width, closeTo(before.width, 0.01));
  });

  testWidgets('标签系统整批移除：老数据里的标签也不再出现在界面上', (tester) async {
    final app = await boot();
    final inspiration = app.ws.captureInspiration('带标签的一条');
    // 直接往数据层写：契约里的字段留着（零迁移），但界面不该再产生、也不再显示它
    app.run(() => app.ws.updateInspirationTags(inspiration.id, <String>['产品', '体验']));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    expect(find.text('#产品'), findsNothing);
    expect(find.text('#体验'), findsNothing);
    expect(find.text('加标签'), findsNothing, reason: '书写区不再有打标签的入口');

    await tester.tap(find.text('带标签的一条'));
    await tester.pumpAndSettle();
    expect(find.text('标签…'), findsNothing, reason: '动作面板里的那一项也删了');
  });

  testWidgets('筛空了要说清"还有多少条"，不能假装灵感箱是空的', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '甲');
    app.run(() => app.ws.captureInspiration('归到甲的想法', projectId: project.id));
    app.run(() => app.ws.captureInspiration('没归属的想法'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 点条目上的项目名 → 只看「甲」
    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();

    // 把甲下唯一一条丢弃：列表空了，但箱子里还剩 1 条
    await tester.tap(find.text('归到甲的想法'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃'));
    await tester.pumpAndSettle();

    expect(find.text('没有符合筛选的灵感'), findsOneWidget);
    expect(find.textContaining('未处理共 1 条'), findsWidgets,
        reason: '筛选条与空态各说一次"一共还有多少条"');
    expect(find.text('清除筛选'), findsWidgets, reason: '筛选条与空态各给一次出口');
  });

  testWidgets('已归档项目下的灵感真的从列表里消失，并给一行去处提示（Q10）', (tester) async {
    final app = await boot();
    final live = app.ws.createProject(title: '还在做的项目');
    final archived = app.ws.createProject(title: '归档掉的项目');
    app.run(() => app.ws.captureInspiration('看得见的灵感', projectId: live.id));
    app.run(() => app.ws.captureInspiration('被藏起来的灵感', projectId: archived.id));
    app.run(() => app.ws.setProjectArchived(archived.id, true));

    // 数据层：列表与统计都是同一个口径
    expect(app.ws.inspirationInbox.map((i) => i.text), <String>['看得见的灵感']);
    expect(app.ws.inspirationsHiddenByArchivedProjects, 1);

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    expect(find.text('看得见的灵感'), findsOneWidget);
    expect(find.text('被藏起来的灵感'), findsNothing, reason: '归档项目承诺过它不再占列表');
    expect(find.text('未处理 1 条'), findsOneWidget, reason: '计数与列表同一套取数');
    expect(
      find.textContaining('另有 1 条在已归档项目下'),
      findsOneWidget,
      reason: '从列表里消失的东西必须有个去处，不能静默吞掉',
    );

    // 取消归档 → 回到列表，提示也随之消失
    app.run(() => app.ws.setProjectArchived(archived.id, false));
    await tester.pumpAndSettle();
    expect(find.text('被藏起来的灵感'), findsOneWidget);
    expect(find.textContaining('另有 1 条在已归档项目下'), findsNothing);
    expect(find.text('未处理 2 条'), findsOneWidget);
  });

  testWidgets('全部灵感都被归档项目遮住时，空态也要说清"去哪看"（Q10）', (tester) async {
    final app = await boot();
    final archived = app.ws.createProject(title: '归档掉的项目');
    app.run(() => app.ws.captureInspiration('被藏起来的灵感', projectId: archived.id));
    app.run(() => app.ws.setProjectArchived(archived.id, true));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // 空箱文案是**轮换**的（ADR-084），所以这里断言"是表里的某一句"，
    // 而不是钉死一句话；种子存在偏好里，本次会话固定
    expect(
      emptyBoxLines.any((line) => find.text(line).evaluate().isNotEmpty),
      isTrue,
      reason: '空箱应当显示轮换文案里的某一句',
    );
    expect(app.prefs.emptyBoxSeed, isNotNull, reason: '启动时应当抽过一次并落进偏好');
    expect(
      find.textContaining('另有 1 条在已归档项目下'),
      findsWidgets,
      reason: '"空"是算出来的空 —— 不说清楚，用户会以为灵感被删了'
          '（提示条与空态各说一次，说明这条信息确实显眼）',
    );
  });

  testWidgets('空箱文案：同一个会话里切走再回来不变（每次启动才重抽）', (tester) async {
    final app = await boot();

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    String? shown() {
      for (final line in emptyBoxLines) {
        if (find.text(line).evaluate().isNotEmpty) return line;
      }
      return null;
    }

    final first = shown();
    expect(first, isNotNull);

    // 切到项目页再切回来
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('灵感')),
    );
    await tester.pumpAndSettle();

    expect(shown(), first, reason: '本次会话里不许换句 —— 每进一次换一句会晃眼');
  });
}
