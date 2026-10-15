import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/line_check_mark.dart';
import 'package:guideline/ui/events/event_detail_page.dart';
import 'package:guideline/ui/more/all_tasks_page.dart';

/// 任务**待办清单**的界面接线（《数据契约》§3.4.2）。
///
/// 这一份测"点得到吗、看得到吗、勾了之后数据对不对"，不测判定规则
/// （那是 `test/core/workspace_task_checklist_test.dart` 的事）。
///
/// 两处落点都要覆盖，因为它们共用同一份数据但渲染在完全不同的容器里：
///   · **事件详情页** —— 任务框里、子任务上方，靠缩进 + 浅底表示层级；
///   · **任务行**（「全部任务」「接下来的任务」「日历」「搜索」共用）
///     —— 就地展开、就地勾，用户不必进事件详情。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_task_checklist_ui_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() =>
      AppController.bootstrap(dataDirectoryOverride: tempDir);

  /// 待办行的 key（`taskChecklistRowKeyPrefix + 条目 id`）。
  Finder rowKey(String itemId) =>
      find.byKey(ValueKey<String>('$taskChecklistRowKeyPrefix$itemId'));

  /// 打开事件详情页（照 `task_row_actions_test` 那条路径：外壳 → 事件 → 卡片）。
  Future<void> openEvent(WidgetTester tester, AppController app, String name) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  /// 点某一行待办的**勾选记号**（不是点整行：列表页里点整行也是勾，
  /// 详情页里点文字是改名 —— 两种落点都要按得到）。
  ///
  /// 2026-10-15 起这个记号是**自绘的一条线**（勾上时下折成对勾，`LineCheckMark`），
  /// 不再是 `Icons.radio_button_unchecked` —— 所以改按它自己的 Key 找。
  Future<void> tapCircle(WidgetTester tester, String itemId) async {
    await tester.tap(find.byKey(lineCheckMarkKey(itemId)));
    await tester.pumpAndSettle();
  }

  /// 某一条的记号**勾上没有**（读那个自绘控件的入参）。
  bool markChecked(WidgetTester tester, String itemId) => tester
      .widget<LineCheckMark>(find.byKey(lineCheckMarkKey(itemId)))
      .checked;

  group('事件详情页', () {
    testWidgets('待办行的行距不许再涨回去（用户 2026-10-16："间距太高了"）', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      app.ws.addTaskChecklistItem(task.id, '第一条');
      app.ws.addTaskChecklistItem(task.id, '第二条');
      app.ws.addTaskChecklistItem(task.id, '第三条');

      await openEvent(tester, app, '演示事件');

      // 相邻两条待办**文字的 top 之差**就是这一行的实际行距 ——
      // 比量某个内部控件的高度可靠：用户看到的就是这个数。
      final first = tester.getRect(find.text('第一条')).top;
      final second = tester.getRect(find.text('第二条')).top;
      final third = tester.getRect(find.text('第三条')).top;

      expect(second - first, lessThanOrEqualTo(28),
          reason: '一行待办不许超过 28dp（实测 26）；'
              '涨回去多半是勾选那一格又用了 `IconButton` —— 它会自己撑到 48dp，'
              '`constraints` 压不住（见 event_detail_page 里那段注释）');
      expect(third - second, lessThanOrEqualTo(28), reason: '行距要一致');
      expect(second - first, greaterThan(18),
          reason: '太挤也不行：记号 18 + 四周留白，一行至少 20 出头');
    });

    testWidgets('待办排在任务与它的下级之间，用缩进表示层级、没有从属符', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');
      app.run(() => app.ws.createTask(
            eventId: event.id,
            title: '子任务甲',
            parentTaskId: task.id,
            type: TaskType.subtask,
          ));

      await openEvent(tester, app, '演示事件');

      // 三行的纵向次序：任务行 → 待办行 → 子任务行
      final taskRow = tester.getRect(find.text('写解析层'));
      final checklistRow = tester.getRect(rowKey(item.id));
      final childRow = tester.getRect(find.text('子任务甲'));
      expect(checklistRow.top, greaterThan(taskRow.bottom), reason: '待办在任务行下方');
      expect(checklistRow.bottom, lessThan(childRow.top), reason: '待办排在下级之前');

      // 真缩进：待办那一行的**文字**比子任务行的文字更靠右（两者字号相同，
      // 所以左缘可比）。待办行刻意比子任务多缩进一档 —— 层级只靠缩进表示。
      final checklistText = tester.getRect(
        find.descendant(of: rowKey(item.id), matching: find.text('先写契约')),
      );
      expect(checklistText.left, greaterThan(childRow.left),
          reason: '待办文字（${checklistText.left}）应当比子任务文字（${childRow.left}）更靠右');

      // **没有从属符**：子任务那套"短竖线 + 从属箭头"不出现在待办行里
      expect(
        find.descendant(
          of: rowKey(item.id),
          matching: find.byIcon(Icons.subdirectory_arrow_right),
        ),
        findsNothing,
        reason: '待办只用缩进区分，不画从属符',
      );
    });

    testWidgets('录入走动作面板：点任务行 →「添加待办」→ 框内直接是输入框 → 确认加一条', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');

      await openEvent(tester, app, '演示事件');

      // 任务框里**平时不画**录入行（2026-10-11 用户口径）
      expect(find.text('加一条待办'), findsNothing, reason: '录入入口已挪进动作面板');

      // 点任务行 → 动作面板 → 「添加待办」
      await tester.tap(find.text('写解析层'));
      await tester.pumpAndSettle();
      expect(find.text('添加待办'), findsOneWidget, reason: '动作面板里要有这一项');
      await tester.tap(find.text('添加待办'));
      await tester.pumpAndSettle();

      // 点完就是输入框（不需要再点一次），而且自动聚焦
      final focused = find.byWidgetPredicate(
        (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
        description: '当前获得焦点的输入框',
      );
      expect(focused, findsOneWidget, reason: '点完「添加待办」就直接能打字');

      await tester.enterText(focused, '先写契约');
      await tester.tap(find.byTooltip('确认'));
      await tester.pumpAndSettle();

      expect(app.ws.taskChecklistOf(task.id).map((i) => i.text), <String>['先写契约']);
      expect(find.text('待办 0/1'), findsOneWidget, reason: '摘要跟着出来');
      // 2026-10-15 起：建完一条**留在编辑态接着录**（用户要求"连续输入"），
      // 退出只有点空白 / 点叉号 / 收键盘三条路
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
        ),
        findsOneWidget,
        reason: '加完不收起来，接着录下一条',
      );
      expect(
        tester.widget<TextField>(focused).controller!.text,
        isEmpty,
        reason: '上一条已经建出去了，框里要清空',
      );
    });

    testWidgets('连续录入：确认三次建出三条，中途不收输入框（2026-10-15 用户要求）', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');

      await openEvent(tester, app, '演示事件');
      await tester.tap(find.text('写解析层'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加待办'));
      await tester.pumpAndSettle();

      final focused = find.byWidgetPredicate(
        (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
        description: '当前获得焦点的输入框',
      );

      for (final text in <String>['第一条', '第二条', '第三条']) {
        await tester.enterText(focused, text);
        await tester.tap(find.byTooltip('确认'));
        await tester.pumpAndSettle();
        // 每建一条之后**都还在编辑态**，不必再点一次「添加待办」
        expect(focused, findsOneWidget, reason: '建完「$text」之后还该接着录');
      }

      expect(
        app.ws.taskChecklistOf(task.id).map((i) => i.text),
        <String>['第一条', '第二条', '第三条'],
        reason: '三次确认 = 三条待办',
      );
      expect(find.text('待办 0/3'), findsOneWidget);
    });

    testWidgets('退出连续录入的三条路：点叉号 / 点空白 / 收键盘', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');

      await openEvent(tester, app, '演示事件');

      Future<void> openComposer() async {
        await tester.tap(find.text('写解析层'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加待办'));
        await tester.pumpAndSettle();
      }

      // ① 点**叉号**：收起，不加
      await openComposer();
      await tester.enterText(
        find.byWidgetPredicate((Widget w) => w is TextField && w.focusNode!.hasFocus),
        '这条不要',
      );
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      expect(app.ws.taskChecklistOf(task.id), isEmpty);
      expect(find.byTooltip('取消'), findsNothing, reason: '叉号要把它收掉');

      // ② 点**空白**（输入框那一块之外）：收起
      await openComposer();
      await tester.enterText(
        find.byWidgetPredicate((Widget w) => w is TextField && w.focusNode!.hasFocus),
        '半截话',
      );
      // 点卡片左上角那片留白 —— 它在录入行之外
      await tester.tapAt(tester.getTopLeft(find.byType(EventDetailPage)) + const Offset(4, 200));
      await tester.pumpAndSettle();
      expect(find.byTooltip('取消'), findsNothing, reason: '点空白也要收掉');
      expect(app.ws.taskChecklistOf(task.id), isEmpty, reason: '没按确认的不算数');

      // ③ 收起键盘：框里剩的那句**照样建出去**（与全应用同一条"收键盘 = 我写完了"），
      //    然后这一行收起
      await openComposer();
      await tester.enterText(
        find.byWidgetPredicate((Widget w) => w is TextField && w.focusNode!.hasFocus),
        '最后一条',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(
        app.ws.taskChecklistOf(task.id).map((i) => i.text),
        <String>['最后一条'],
        reason: '收键盘 = 确认：打了一半的那句不该丢',
      );
      expect(find.byTooltip('取消'), findsNothing, reason: '收键盘要把它收掉');
    });

    testWidgets('录入：空的按确认什么都不加；按取消也不加，两者都收起输入行', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');

      await openEvent(tester, app, '演示事件');

      Future<Finder> openComposer() async {
        await tester.tap(find.text('写解析层'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加待办'));
        await tester.pumpAndSettle();
        return find.byWidgetPredicate(
          (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
          description: '当前获得焦点的输入框',
        );
      }

      // ① 空 + 确认 ⇒ 不加，且收起
      var focused = await openComposer();
      expect(focused, findsOneWidget);
      await tester.tap(find.byTooltip('确认'));
      await tester.pumpAndSettle();
      expect(app.ws.taskChecklistOf(task.id), isEmpty, reason: '空的不许建出一条待办');
      expect(find.byTooltip('确认'), findsNothing, reason: '空确认也要把输入行收掉');

      // ② 有字 + 取消 ⇒ 不加，且收起
      focused = await openComposer();
      await tester.enterText(focused, '这条不算数');
      await tester.tap(find.byTooltip('取消'));
      await tester.pumpAndSettle();
      expect(app.ws.taskChecklistOf(task.id), isEmpty, reason: '取消就是不要它');
      expect(find.byTooltip('取消'), findsNothing, reason: '取消要把输入行收掉');
    });

    testWidgets('勾一条待办：只改它自己 —— 任务状态与子任务一律不动', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');
      final child = app.ws.createTask(
        eventId: event.id,
        title: '子任务甲',
        parentTaskId: task.id,
        type: TaskType.subtask,
      );

      await openEvent(tester, app, '演示事件');
      await tapCircle(tester, item.id);

      expect(app.ws.taskChecklistOf(task.id).single.done, isTrue, reason: '待办真的勾上了');
      expect(app.ws.findTask(task.id)!.status, NodeStatus.pending, reason: '任务状态不许跟着变');
      expect(app.ws.findTask(child.id)!.status, NodeStatus.pending);
      expect(find.text('待办 1/1'), findsOneWidget, reason: '摘要跟着走');
    });

    testWidgets('默认展开规则：有未勾完的展开；展开后切到「收起」再点就收起来', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');

      await openEvent(tester, app, '演示事件');
      expect(find.text('待办 0/1'), findsOneWidget);
      expect(rowKey(item.id), findsOneWidget, reason: '有未勾完的待办 ⇒ 默认展开');

      // 点摘要那一行收起
      await tester.tap(find.text('待办 0/1'));
      await tester.pumpAndSettle();
      expect(rowKey(item.id), findsNothing, reason: '收起后不画条目行');
      expect(find.text('待办 0/1'), findsOneWidget, reason: '收起时留一行摘要');

      // 再点开回来
      await tester.tap(find.text('待办 0/1'));
      await tester.pumpAndSettle();
      expect(rowKey(item.id), findsOneWidget);
    });

    testWidgets('勾完的待办划掉；摘要照写 d/t，任务仍要手动标记完成', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      final item = app.ws.addTaskChecklistItem(task.id, '先写契约');

      // 先用数据把它勾上，**再**打开页面。全勾完之后按默认规则是**收起**的
      // （摘要还在，条目行不画）—— 这也顺手把"收起时留摘要"那一条验了。
      app.run(() => app.ws.setTaskChecklistItemDone(task.id, item.id, true));
      await openEvent(tester, app, '演示事件');

      expect(find.text('待办 1/1'), findsOneWidget);
      expect(rowKey(item.id), findsNothing, reason: '全勾完 ⇒ 默认收成一行摘要');

      // 点摘要展开，看勾完的条目长什么样
      await tester.tap(find.text('待办 1/1'));
      await tester.pumpAndSettle();
      expect(rowKey(item.id), findsOneWidget);

      final text = tester.widget<Text>(
        find.descendant(of: rowKey(item.id), matching: find.byType(Text)),
      );
      expect(text.style?.decoration, TextDecoration.lineThrough, reason: '勾完的条目要划掉');
      expect(markChecked(tester, item.id), isTrue, reason: '勾选记号要变成对勾');
      expect(app.ws.findTask(task.id)!.status, NodeStatus.pending,
          reason: '待办全勾完也不许自动完成任务');

      // 再点一次把它取消：两态要能来回
      await tapCircle(tester, item.id);
      expect(app.ws.taskChecklistOf(task.id).single.done, isFalse);
      expect(app.ws.findTask(task.id)!.status, NodeStatus.pending);
      expect(find.text('待办 0/1'), findsOneWidget);
    });
  });

  group('任务行（全部任务 / 接下来的任务 / 日历共用）', () {
    Future<AppController> bootWithChecklist({int items = 2}) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      final task = app.ws.createTask(eventId: event.id, title: '写解析层');
      for (var i = 0; i < items; i += 1) {
        app.ws.addTaskChecklistItem(task.id, '细则 ${i + 1}');
      }
      return app;
    }

    Future<void> openAllTasks(WidgetTester tester, AppController app) async {
      await tester.pumpWidget(MaterialApp(home: AllTasksPage(app: app)));
      await tester.pumpAndSettle();
    }

    testWidgets('摘要与展开箭头上行；展开后能就地勾，且**不跳进事件详情**', (tester) async {
      final app = await bootWithChecklist();
      final task = app.ws.findTask(app.ws.liveTasks.single.id)!;
      final items = app.ws.taskChecklistOf(task.id);

      await openAllTasks(tester, app);
      expect(find.text('待办 0/2'), findsOneWidget, reason: '任务行副标题带摘要');

      // 有未勾完的待办 ⇒ 默认展开，所以这里是「收起」；先收起再展开，两个方向都走一遍
      await tester.tap(find.byTooltip('收起待办'));
      await tester.pumpAndSettle();
      expect(rowKey(items.first.id), findsNothing, reason: '收起后不画条目行');

      await tester.tap(find.byTooltip('展开待办'));
      await tester.pumpAndSettle();
      expect(rowKey(items.first.id), findsOneWidget, reason: '展开区里画出条目');

      // 点整行 = 勾选，**不跳转**（跳了的话这一页就没了）
      await tester.tap(rowKey(items.first.id));
      await tester.pumpAndSettle();

      expect(app.ws.taskChecklistOf(task.id).first.done, isTrue);
      expect(find.byType(AllTasksPage), findsOneWidget, reason: '勾待办不该离开这一页');
      expect(find.byType(EventDetailPage), findsNothing);
      expect(find.text('待办 1/2'), findsOneWidget, reason: '摘要即时更新');
    });

    testWidgets('点标题仍然进事件详情（展开箭头不吃掉整行的点击）', (tester) async {
      final app = await bootWithChecklist();
      await openAllTasks(tester, app);

      await tester.tap(find.text('写解析层'));
      await tester.pumpAndSettle();

      expect(find.byType(EventDetailPage), findsOneWidget);
    });

    testWidgets('没有待办的任务行：不给箭头（点了没反应的箭头比没有更烦人）', (tester) async {
      final app = await boot();
      final event = app.ws.createEvent(name: '演示事件');
      app.ws.createTask(eventId: event.id, title: '没有细则的任务');

      await openAllTasks(tester, app);

      expect(find.byTooltip('展开待办'), findsNothing);
      expect(find.textContaining('待办 '), findsNothing);
    });

    testWidgets('多选态下勾不到待办（那一行整行只认"选中"）', (tester) async {
      final app = await bootWithChecklist();
      final task = app.ws.findTask(app.ws.liveTasks.single.id)!;
      final items = app.ws.taskChecklistOf(task.id);

      await openAllTasks(tester, app);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选'), findsOneWidget, reason: '确实进了多选态');

      // 多选态下整行被 `AbsorbPointer` 挡住，点哪儿都不会勾到待办
      // （`TaskTile` 的展开钮与展开区里的勾选一起失效）。
      // 用 `tapAt` 而不是 `tap`：`tap` 会先做命中检查，被挡住时直接报
      // "找不到可点的控件"，那就没验到"点了没反应"这件事。
      final rect = tester.getRect(find.text('写解析层'));
      await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
      await tester.tapAt(rect.center);
      await tester.pumpAndSettle();

      expect(app.ws.taskChecklistOf(task.id).first.done, isFalse, reason: '一条都不该被勾上');
      // 展开状态也一个字没动：有待办的默认就是展开，点它**不该**被收起
      // （点得动的话，第一下就会把清单收走 —— 那是最容易被忽略的一种"误触"）。
      expect(
        app.isExpanded('checklist-${task.id}', defaultExpanded: true),
        isTrue,
        reason: '多选态下的点击不该改动待办的展开状态',
      );
      expect(rowKey(items.first.id), findsOneWidget);
    });
  });
}
