import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/core/models/task.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/events/event_detail_page.dart';
import 'package:guideline/ui/events/task_fold.dart';

/// 事件页改成"与项目页同一套观感"之后的接线：
///   · 一个事件一张卡，卡里嵌着主线任务（不用点进去就能看到做到哪）；
///   · 已完成的节点自动收起，只留当前节点的上一个（规则与详情页共用）；
///   · 卡头能展开 / 收起整条线。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_event_tab_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('autoFoldedMainLineIds（列表页与详情页共用的规则）', () {
    Task task(String id, NodeStatus status) => Task(
          id: id,
          eventId: 'e1',
          parentTaskId: null,
          taskType: TaskType.standard,
          title: '任务 $id',
          dueAt: null,
          status: status,
          archived: false,
          order: 1000,
          completedAt: status == NodeStatus.done ? 1700000000000 : null,
          createdAt: 1700000000000,
          updatedAt: 1700000000000,
          deleted: false,
        );

    test('只收起"当前节点上一个"之前的已完成节点', () {
      final folded = autoFoldedMainLineIds(<Task>[
        task('a', NodeStatus.done),
        task('b', NodeStatus.done),
        task('c', NodeStatus.done),
        task('d', NodeStatus.pending),
      ]);
      expect(folded, <String>{'a', 'b'}, reason: 'c 是当前节点（d）的上一个，要留着');
    });

    test('全是终态就不折（否则整条线会消失）', () {
      expect(
        autoFoldedMainLineIds(<Task>[
          task('a', NodeStatus.done),
          task('b', NodeStatus.ignored),
        ]),
        isEmpty,
      );
    });

    test('空线、以及当前节点就在第一位时都不折', () {
      expect(autoFoldedMainLineIds(<Task>[]), isEmpty);
      expect(
        autoFoldedMainLineIds(<Task>[
          task('a', NodeStatus.pending),
          task('b', NodeStatus.pending),
        ]),
        isEmpty,
      );
    });

    test('用户手动展开过的节点有豁免', () {
      final folded = autoFoldedMainLineIds(
        <Task>[
          task('a', NodeStatus.done),
          task('b', NodeStatus.done),
          task('c', NodeStatus.pending),
        ],
        userExpanded: (id) => id == 'a',
      );
      expect(folded, isEmpty, reason: 'a 被显式展开过，就不该再被自动收起');
    });
  });


  Future<AppController> bootWithLine(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '秋季发布');
    for (final title in <String>['第一步', '第二步', '第三步', '第四步']) {
      final task = app.ws.createTask(eventId: event.id, title: title);
      if (title != '第四步') {
        app.run(() => app.ws.setTaskStatus(task.id, NodeStatus.done));
      }
    }
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('事件卡里直接列出主线任务，且已完成的自动收起', (tester) async {
    await bootWithLine(tester);

    // 卡头一眼看到进度
    expect(find.text('主线 3/4 已完成'), findsOneWidget);
    // 卡头只留进度与状态记号：**不再**写"最近到期 / 接下来做什么"
    // （那一版挪进详情页后又整块撤掉了，见 CHANGELOG 1.5.0）
    expect(
      find.textContaining('接下来'),
      findsNothing,
      reason: '列表卡头不写"最近到期 / 接下来"',
    );

    // 卡里嵌着任务：当前节点与它的上一个看得见
    expect(find.text('第四步'), findsOneWidget);
    expect(find.text('第三步'), findsOneWidget);
    // 更早的已完成节点被收起，并明说收了几条
    expect(find.text('第一步'), findsNothing);
    expect(find.text('第二步'), findsNothing);
    expect(find.textContaining('另有 2 个已完成节点'), findsOneWidget);

    // 进详情页：那一版摘要已经撤掉，页面上不该再有它
    await tester.tap(find.text('秋季发布'));
    await tester.pumpAndSettle();
    expect(find.text('时间与任务'), findsNothing);
    expect(find.text('最近到期'), findsNothing);
  });

  testWidgets('卡头能收起整条线，再点一次展开', (tester) async {
    final app = await bootWithLine(tester);
    final event = app.ws.liveEvents.single;

    expect(find.text('第四步'), findsOneWidget);

    // 箭头现在只有一个 `chevron_right`（靠旋转表达展开 / 收起），所以数它的朝向
    double arrowTurns() => tester
        .widget<RotationTransition>(
          find.byType(RotationTransition).first,
        )
        .turns
        .value;
    expect(arrowTurns(), closeTo(0.25, 0.001), reason: '展开态：箭头朝下');

    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final middle = arrowTurns();
    expect(middle, greaterThan(0.02), reason: '箭头应当正在转');
    expect(middle, lessThan(0.23));
    await tester.pumpAndSettle();
    expect(find.text('第四步'), findsNothing, reason: '收起后卡里不该还有任务行');
    expect(arrowTurns(), closeTo(0, 0.001), reason: '收起态：箭头朝右');
    expect(app.isExpanded(event.id), isFalse, reason: '折叠状态要记进偏好');

    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    expect(find.text('第四步'), findsOneWidget);
    expect(arrowTurns(), closeTo(0.25, 0.001));
    expect(app.isExpanded(event.id), isTrue);
  });

  testWidgets('老数据里的并列任务：按子任务行显示，不再有「并列」字样', (tester) async {
    // 手写一份"老文件"（`parallel` 已废除，但老文件里还有），走真实启动路径读进来
    final eventId = 'e0000000-0000-4000-8000-000000000001';
    final mainId = 'a0000000-0000-4000-8000-000000000001';
    final legacyId = 'a0000000-0000-4000-8000-000000000002';
    String taskJson(String id, String title, String type, String? parent) =>
        '{"id":"$id","event_id":"$eventId","parent_task_id":'
        '${parent == null ? 'null' : '"$parent"'},"next_task_ids":[],'
        '"task_type":"$type","title":"$title","due_at":null,"status":"pending",'
        '"archived":false,"order":1000,"completed_at":null,"created_at":1,'
        '"updated_at":1,"deleted":false}';
    File('${tempDir.path}${Platform.pathSeparator}guideline.json').writeAsStringSync(
      '{"schemaVersion":2,"savedAt":1,"collections":{'
      '"projects":{"items":[]},"inspirations":{"items":[]},'
      '"events":{"items":[{"id":"$eventId","name":"老事件","status":"pending",'
      '"archived":false,"order":1000,"completed_at":null,"created_at":1,'
      '"updated_at":1,"deleted":false}]},'
      '"tasks":{"items":['
      '${taskJson(mainId, '老主线', 'standard', null)},'
      '${taskJson(legacyId, '老记录', 'parallel', mainId)}'
      ']}}}\n',
    );

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('老事件'));
    await tester.pumpAndSettle();

    expect(find.byType(EventDetailPage), findsOneWidget);
    expect(find.text('老记录'), findsOneWidget, reason: '老记录不能因为类型废除就消失');
    expect(find.textContaining('并列'), findsNothing, reason: '界面上不该再出现这个概念');
  });

  testWidgets('已归档的任务不画在任务线上，进度 / 折叠 / 锁同一套取数（Q18）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一条线');
    final first = app.ws.createTask(eventId: event.id, title: '第一步');
    final second = app.ws.createTask(eventId: event.id, title: '第二步');
    app.run(() => app.ws.setTaskStatus(first.id, NodeStatus.done));
    final archivedNode = app.ws.createTask(eventId: event.id, title: '被归档的节点');
    // 子任务一归档一留着：父任务框里的「下级 d/t」分母只算留着的那个
    final keptSub = app.ws.createTask(
      eventId: event.id,
      title: '留着的子任务',
      parentTaskId: second.id,
      type: TaskType.subtask,
    );
    final archivedSub = app.ws.createTask(
      eventId: event.id,
      title: '归档的子任务',
      parentTaskId: second.id,
      type: TaskType.subtask,
    );
    app.run(() => app.ws.setTaskArchived(archivedNode.id, true));
    app.run(() => app.ws.setTaskArchived(archivedSub.id, true));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    // 进度：分母排除归档（第一步 + 第二步 = 2），分子含已完成（1）
    expect(find.text('主线 1/2 已完成'), findsOneWidget);
    expect(find.text('被归档的节点'), findsNothing, reason: '已归档的不画在任务线上');
    expect(find.text('归档的子任务'), findsNothing);

    // 进详情页看「下级 d/t」：少的那一条与归档的也是同源
    await tester.tap(find.text('第二步'));
    await tester.pumpAndSettle();
    expect(find.text('下级 0/1'), findsOneWidget, reason: '分母只算留着的那个子任务');
    expect(keptSub.id, isNotEmpty);
    expect(archivedSub.id, isNotEmpty);

    // 留着的子任务做完 → 锁消失、父任务可以勾
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).last);
    await tester.pumpAndSettle();
    expect(app.ws.findTask(keptSub.id)!.status, NodeStatus.done);
  });

  testWidgets('1.6 倍字体 + 很长的标题：事件卡不溢出', (tester) async {    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '一个名字相当长的事件名，用来撑满一行看看会不会挤爆');
    for (var i = 1; i <= 8; i += 1) {
      final task = app.ws.createTask(
        eventId: event.id,
        title: '第 $i 步：一条名字相当长的主线任务标题',
      );
      if (i <= 6) app.run(() => app.ws.setTaskStatus(task.id, NodeStatus.done));
    }

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '布局溢出会在这里抛出来');
    expect(find.textContaining('另有 5 个已完成节点'), findsOneWidget);
  });

  testWidgets('点卡里的任务行同样能进事件详情', (tester) async {
    await bootWithLine(tester);

    await tester.tap(find.text('第四步'));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailPage), findsOneWidget);
  });

  testWidgets('折起来的老节点能就地展开，再点一次收回去', (tester) async {
    await bootWithLine(tester);
    expect(find.text('第一步'), findsNothing, reason: '默认是收起的');

    await tester.tap(find.textContaining('另有 2 个已完成节点'));
    await tester.pumpAndSettle();

    // 就地展开：不用跳进详情页，被收起的老节点直接出现在卡里
    expect(find.text('第一步'), findsOneWidget);
    expect(find.text('第二步'), findsOneWidget);
    expect(find.text('第四步'), findsOneWidget);
    expect(find.byType(EventDetailPage), findsNothing, reason: '应当是就地展开，不是跳页');
    expect(find.text('收起已完成节点'), findsOneWidget);

    await tester.tap(find.text('收起已完成节点'));
    await tester.pumpAndSettle();
    expect(find.text('第一步'), findsNothing);
    expect(find.textContaining('另有 2 个已完成节点'), findsOneWidget);
  });

  testWidgets('详情页里也能把自动收起的节点展开', (tester) async {
    await bootWithLine(tester);

    await tester.tap(find.text('第四步'));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailPage), findsOneWidget);

    // 详情页按同一条规则折叠 —— 但它同样给了"就地展开"的出路
    expect(find.text('第一步'), findsNothing);
    await tester.tap(find.textContaining('另有 2 个已完成节点'));
    await tester.pumpAndSettle();
    expect(find.text('第一步'), findsOneWidget);
    expect(find.text('第二步'), findsOneWidget);
  });

  testWidgets('已搁置的事件：日期不再标成逾期红，也不计入「逾期」', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final dropped = app.ws.createEvent(name: '放下的事');
    final droppedTask = app.ws.createTask(eventId: dropped.id, title: '搁置线的任务');
    app.run(() => app.ws.updateTask(droppedTask.id, dueAt: '2000-01-01'));
    app.run(() => app.ws.setEventStatus(dropped.id, NodeStatus.ignored));

    final active = app.ws.createEvent(name: '还在做的事');
    final activeTask = app.ws.createTask(eventId: active.id, title: '进行中线的任务');
    app.run(() => app.ws.updateTask(activeTask.id, dueAt: '2000-01-01'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.text('搁置线的任务'))).colorScheme;
    // 不按全屏 Text 数"逾期"文案：列表卡头虽然不再写日期了，但全屏计数仍然脆
    // （卡片里还有别的日期文案）。两条任务各自的日期由下面的 colorOf 逐条取。

    Color? colorOf(String taskTitle) {
      final row = find.ancestor(
        of: find.text(taskTitle),
        matching: find.byType(ListTile),
      );
      final text = tester.widget<Text>(
        find.descendant(of: row, matching: find.textContaining('逾期')),
      );
      return text.style?.color;
    }

    expect(colorOf('进行中线的任务'), scheme.error, reason: '在进行的事件里，逾期就该标红');
    expect(colorOf('搁置线的任务'), isNot(scheme.error), reason: '搁置了就不该再催');

    // 数据层：搁置事件下的任务不进「逾期」取数（Q19 的唯一出处）
    expect(app.ws.overdueTasks().map((t) => t.title), <String>['进行中线的任务']);
  });

  testWidgets('已搁置的事件在列表里有记号', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final event = app.ws.createEvent(name: '搬家');
    final near = app.ws.createTask(eventId: event.id, title: '先做这个');
    app.run(() => app.ws.updateTask(near.id, dueAt: '2026-09-28'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    // 搁置的事件在列表里原本和正常事件长得一样，用户没法解释"为什么它不催我"
    app.run(() => app.ws.setEventStatus(event.id, NodeStatus.ignored));
    await tester.pumpAndSettle();
    expect(find.text('· 已搁置'), findsOneWidget);
  });

  testWidgets('详情页改名收在 ⋮ 里：点「重命名」后标题栏原地变成输入框', (tester) async {
    final app = await bootWithLine(tester);
    final event = app.ws.liveEvents.single;

    await tester.tap(find.text('秋季发布'));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailPage), findsOneWidget);
    // 页内不再摆一份事件名（标题栏已经写着）：卡片里那行标签没了
    expect(find.text('事件名'), findsNothing);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget, reason: '标题栏原地变成输入框');
    await tester.enterText(find.byType(TextField), '冬季发布');
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    expect(app.ws.findEvent(event.id)!.name, '冬季发布');
    expect(find.text('冬季发布'), findsWidgets, reason: '标题栏要立刻显示新名字');
  });

  testWidgets('事件菜单能挪顺序：交换后列表顺序真的变了、也落了盘（Q28）', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final first = app.ws.createEvent(name: '甲线');
    final second = app.ws.createEvent(name: '乙线');

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();

    double topOf(String name) => tester.getRect(find.text(name)).top;
    expect(topOf('甲线'), lessThan(topOf('乙线')), reason: '一开始按创建顺序排');

    // 第一条的菜单：往上挪一格已经到头了，必须给一句话
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    expect(find.text('往上挪一格'), findsOneWidget);
    expect(find.text('往下挪一格'), findsOneWidget);
    await tester.tap(find.text('往上挪一格'));
    await tester.pumpAndSettle();
    expect(find.text('已经是最前面了'), findsOneWidget);

    // 让上面那条轻提示先退场（`ScaffoldMessenger` 一次只显示一条）
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    // 往下挪一格：列表顺序真的换了
    await tester.tap(find.byTooltip('更多').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('往下挪一格'));
    await tester.pumpAndSettle();

    expect(topOf('乙线'), lessThan(topOf('甲线')), reason: '事件列表要按新顺序画');
    expect(
      app.ws.findEvent(first.id)!.order,
      greaterThan(app.ws.findEvent(second.id)!.order),
      reason: '交换的是相邻两条的 order',
    );

    // 落盘：重新从磁盘装配一次，顺序不变
    final reloaded = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(
      reloaded.ws.findEvent(first.id)!.order,
      greaterThan(reloaded.ws.findEvent(second.id)!.order),
    );
  });
}
