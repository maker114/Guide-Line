import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/core/models/reminder.dart';
import 'package:guideline/core/rules/reminder_schedule.dart';
import 'package:guideline/core/store/ui_prefs.dart';

/// 提醒规则的守卫（用户 2026-10-03 定的口径）。
///
/// 这一组用例的分量比一般的规则测试更重：**提醒是唯一一个"错了不会有人发现"的功能** ——
/// 少弹一条，用户只会以为"我忘了"，不会当成缺陷来报。所以每条边界都钉一遍。
void main() {
  // 固定"现在"，否则用例会随运行时刻飘（跨过整点就换一组期望值）。
  // 取 11:00 是为了让默认那两档（提前 60 / 10 分钟，到期 12:30 ⇒ 11:30 / 12:20）
  // **都还在未来** —— 否则一进来就落进"错过窗口"那条分支，测不到正常排期。
  final now = DateTime(2026, 10, 3, 11, 0);

  ReminderPlan plan({
    String due = '2026-10-03 12:30',
    String eventName = '交房租',
    bool open = true,
    List<ReminderLead> leads = ReminderLead.defaults,
    DateTime? at,
  }) =>
      planTaskReminders(
        taskId: 't1',
        taskTitle: '转账',
        eventName: eventName,
        dueAt: due,
        open: open,
        leads: leads,
        now: at ?? now,
      );

  group('只认"设置了具体时间"的任务', () {
    test('只有日期、没有时刻 —— 一条都不排', () {
      expect(plan(due: '2026-10-03').isEmpty, isTrue);
    });

    test('根本没排期 —— 一条都不排', () {
      expect(plan(due: '').isEmpty, isTrue);
    });

    test('值不成形态（不是日期）—— 一条都不排，不抛', () {
      expect(plan(due: '今天下午').isEmpty, isTrue);
    });

    test('带时刻 —— 两档都排上，时刻 = 到期时间往回推', () {
      final result = plan();
      expect(result.fires.length, 2);
      expect(result.fires[0].at, DateTime(2026, 10, 3, 11, 30)); // 提前 1 小时
      expect(result.fires[1].at, DateTime(2026, 10, 3, 12, 20)); // 提前 10 分钟
      expect(result.catchUp, isNull);
    });

    test('已排完序列的先后：fires 按时间升序（设置里两档写反了也不乱）', () {
      final result = plan(leads: const <ReminderLead>[
        ReminderLead(minutes: 10, enabled: true),
        ReminderLead(minutes: 60, enabled: true),
      ]);
      expect(result.fires.map((f) => f.slot), <int>[1, 0]);
      expect(result.fires[0].at.isBefore(result.fires[1].at), isTrue);
    });
  });

  group('不开着的任务一律不提醒', () {
    for (final label in <String>['已完成', '已搁置', '已归档']) {
      test('$label —— 一条都不排', () {
        expect(plan(open: false).isEmpty, isTrue);
      });
    }

    test('还没到期就已完成：连补发都不给', () {
      expect(plan(open: false).catchUp, isNull);
    });
  });

  group('到了点就不再提醒', () {
    test('正好到期那一刻 —— 一条都不排（"到点本身不提醒"）', () {
      expect(plan(due: '2026-10-03 11:00').isEmpty, isTrue);
    });

    test('已逾期 —— 一条都不排，也不补发', () {
      final result = plan(due: '2026-10-02 09:00');
      expect(result.fires, isEmpty);
      expect(result.catchUp, isNull);
    });
  });

  group('单档可关', () {
    test('关掉 1 小时那档：只剩 10 分钟那条', () {
      final result = plan(leads: const <ReminderLead>[
        ReminderLead(minutes: 60, enabled: false),
        ReminderLead(minutes: 10, enabled: true),
      ]);
      expect(result.fires.length, 1);
      expect(result.fires.single.slot, 1);
      expect(result.catchUp, isNull);
    });

    test('两档都关：什么都不排（但不算"错过"，不补发）', () {
      final result = plan(leads: const <ReminderLead>[
        ReminderLead(minutes: 60, enabled: false),
        ReminderLead(minutes: 10, enabled: false),
      ]);
      expect(result.isEmpty, isTrue);
    });
  });

  group('错过窗口：立刻补一条，且合并成一条', () {
    test('任务在"提前 1 小时"之后才建：那一档不排，给一条补发', () {
      // 现在 12:05，到期 12:30 —— 11:30 那档已经过去，12:20 那档还在未来。
      final result = plan(at: DateTime(2026, 10, 3, 12, 5));
      expect(result.fires.length, 1);
      expect(result.fires.single.slot, 1);
      expect(result.catchUp, isNotNull);
      expect(result.catchUp!.slot, slotCatchUp);
      expect(result.catchUp!.at, DateTime(2026, 10, 3, 12, 5)); // "立刻" = 现在
    });

    test('补发说的是**真实剩余时间**，不是那一档原本的提前量', () {
      final result = plan(at: DateTime(2026, 10, 3, 12, 5));
      expect(result.catchUp!.body, '交房租 · 还有 25 分钟到期');
    });

    test('两档都过去了：**只补一条**，不是两条', () {
      // 现在 12:05，到期 12:08 —— 11:30 与 11:58 两档都过了。
      final result = plan(due: '2026-10-03 12:08', at: DateTime(2026, 10, 3, 12, 5));
      expect(result.fires, isEmpty);
      expect(result.catchUp, isNotNull);
      expect(result.catchUp!.body, '交房租 · 还有 3 分钟到期');
    });

    test('没有档错过时不补（正常排的那两条不该多一条同义通知）', () {
      expect(plan().catchUp, isNull);
    });

    test('剩余不足一分钟也往上说成 1 分钟，不说"还有 0 分钟"', () {
      final result = plan(
        due: '2026-10-03 12:05',
        at: DateTime(2026, 10, 3, 12, 4, 30),
      );
      expect(result.catchUp!.body, '交房租 · 还有 1 分钟到期');
    });
  });

  group('正文措辞', () {
    test('事件名拼在前面', () {
      final result = plan();
      expect(result.fires[0].body, '交房租 · 还有 1 小时到期');
      expect(result.fires[1].body, '交房租 · 还有 10 分钟到期');
    });

    test('拿不到事件名时只留后半句，不留一个孤零零的分隔号', () {
      final result = plan(eventName: '   ');
      expect(result.fires[0].body, '还有 1 小时到期');
    });

    test('标题就是任务标题', () {
      expect(plan().fires[0].title, '转账');
    });

    test('分钟数说成人话的那一套', () {
      expect(describeLeadMinutes(10), '10 分钟');
      expect(describeLeadMinutes(45), '45 分钟');
      expect(describeLeadMinutes(60), '1 小时');
      expect(describeLeadMinutes(90), '1 小时 30 分钟');
      expect(describeLeadMinutes(1440), '1 天');
      expect(describeLeadMinutes(2880), '2 天');
      expect(describeLeadMinutes(1500), '25 小时');
    });
  });

  group('通知 id', () {
    test('同一任务同一档恒定（重排才撤得干净）', () {
      expect(notificationIdFor('t1', 0), notificationIdFor('t1', 0));
      expect(notificationIdFor('t1', 1), notificationIdFor('t1', 1));
    });

    test('不同任务、不同档互不相同', () {
      final ids = <int>{
        notificationIdFor('t1', 0),
        notificationIdFor('t1', 1),
        notificationIdFor('t2', 0),
        notificationIdFor('t2', 1),
      };
      expect(ids.length, 4);
    });

    test('落在 32 位正整数里（平台只收这个范围）', () {
      for (final id in <String>['t1', '', 'a-very-long-uuid-00000000-1111-2222']) {
        for (final slot in <int>[0, 1, slotCatchUp]) {
          final value = notificationIdFor(id, slot);
          expect(value, greaterThanOrEqualTo(0));
          expect(value, lessThanOrEqualTo(0x7FFFFFFF));
        }
      }
    });
  });

  group('提醒设置进偏好文件（ui_prefs.json）', () {
    test('缺键：默认关 + 两档 60 / 10，都开着', () {
      final prefs = UiPrefs.fromJson(<String, dynamic>{});
      expect(prefs.reminderEnabled, isFalse);
      expect(prefs.reminderLeads.length, ReminderLead.slotCount);
      expect(prefs.reminderLeads[0].minutes, 60);
      expect(prefs.reminderLeads[1].minutes, 10);
      expect(prefs.reminderLeads.every((lead) => lead.enabled), isTrue);
    });

    test('坏值逐个回默认，不抛也不照单全收', () {
      final prefs = UiPrefs.fromJson(<String, dynamic>{
        'reminderEnabled': 'yes', // 不是 bool → 关
        'reminderLeads': <dynamic>[
          <String, dynamic>{'minutes': 0, 'enabled': true}, // 0 → 回默认 60
          <String, dynamic>{'minutes': 999999, 'enabled': true}, // 超一周 → 回默认 10
        ],
      });
      expect(prefs.reminderEnabled, isFalse);
      expect(prefs.reminderLeads[0].minutes, 60);
      expect(prefs.reminderLeads[1].minutes, 10);
    });

    test('只有一档：补齐第二档（契约上这个键长度恒为 2）', () {
      final prefs = UiPrefs.fromJson(<String, dynamic>{
        'reminderLeads': <dynamic>[
          <String, dynamic>{'minutes': 30, 'enabled': true},
        ],
      });
      expect(prefs.reminderLeads.length, 2);
      expect(prefs.reminderLeads[0].minutes, 30);
      expect(prefs.reminderLeads[1].minutes, 10);
    });

    test('写了三档：多出来的丢掉，只留两档', () {
      final prefs = UiPrefs.fromJson(<String, dynamic>{
        'reminderLeads': <dynamic>[
          <String, dynamic>{'minutes': 120, 'enabled': true},
          <String, dynamic>{'minutes': 30, 'enabled': false},
          <String, dynamic>{'minutes': 5, 'enabled': true},
        ],
      });
      expect(prefs.reminderLeads.length, 2);
      expect(prefs.reminderLeads[0].minutes, 120);
      expect(prefs.reminderLeads[1].enabled, isFalse);
    });

    test('整串坏掉（不是数组）→ 回默认两档', () {
      final prefs = UiPrefs.fromJson(<String, dynamic>{'reminderLeads': 'nope'});
      expect(prefs.reminderLeads[0].minutes, 60);
      expect(prefs.reminderLeads[1].minutes, 10);
    });

    test('JSON 往返：开关与两档的分钟数 / 开关状态都原样读回', () {
      const original = UiPrefs(
        reminderEnabled: true,
        reminderLeads: <ReminderLead>[
          ReminderLead(minutes: 90, enabled: true),
          ReminderLead(minutes: 5, enabled: false),
        ],
      );
      final restored = UiPrefs.fromJson(original.toJson());
      expect(restored.reminderEnabled, isTrue);
      expect(restored.reminderLeads[0].minutes, 90);
      expect(restored.reminderLeads[0].enabled, isTrue);
      expect(restored.reminderLeads[1].minutes, 5);
      expect(restored.reminderLeads[1].enabled, isFalse);
    });

    test('copyWith 只动提醒两格，不把别的设置弄丢', () {
      const original = UiPrefs(themeId: 'plum', lastTabIndex: 3);
      final changed = original.copyWith(
        reminderEnabled: true,
        reminderLeads: const <ReminderLead>[
          ReminderLead(minutes: 120, enabled: true),
          ReminderLead(minutes: 30, enabled: true),
        ],
      );
      expect(changed.reminderEnabled, isTrue);
      expect(changed.reminderLeads[0].minutes, 120);
      expect(changed.themeId, 'plum');
      expect(changed.lastTabIndex, 3);
    });
  });

  // -------------------------------------------------------------------- 今日事
  //
  // 2026-10-15 加的那一条（ADR-099）：**到期日就是今天、而没设具体时刻**的任务，
  // 当天零点汇总一句。它与上面那两档并列、互不改写 —— 所以这一组的期望值
  // 全部按"只有日期"来写，凡是带时刻的都应当被排除在外。
  //
  // 2026-10-29 起正文附上事件名（用户："提醒当天的事件时，需要在通知里附上事件名称"）：
  // 入参换成 [DailyDigestTask]，事件名去重、按任务顺序全列；查不到事件名时退回原句。
  group('今日事（当天零点的汇总）', () {
    final morning = DateTime(2026, 10, 15, 0, 0);
    final noon = DateTime(2026, 10, 15, 12, 30);

    /// 默认不给事件名（等价于"事件查不到"）；要验带名字的正文就传 `events`。
    ReminderFire? digest(
      List<String?> dues, {
      DateTime? at,
      List<String> events = const <String>[],
    }) =>
        planDailyDigest(
          tasks: <DailyDigestTask>[
            for (var index = 0; index < dues.length; index += 1)
              DailyDigestTask(
                dueAt: dues[index],
                eventName: index < events.length ? events[index] : '',
              ),
          ],
          now: at ?? morning,
        );

    test('今天有只写到天的任务 —— 落在**今天零点**', () {
      final fire = digest(<String?>['2026-10-15']);
      expect(fire, isNotNull);
      expect(fire!.at, DateTime(2026, 10, 15, 0, 0));
      expect(fire.slot, slotDailyDigest);
      expect(fire.taskId, dailyDigestTaskId);
    });

    test('正文只说条数（没有事件名可列时，不硬凑一个冒号）', () {
      expect(digest(<String?>['2026-10-15'])!.body, '今天有 1 件事到期');
      expect(
        digest(<String?>['2026-10-15', '2026-10-15', '2026-10-15'])!.body,
        '今天有 3 件事到期',
      );
    });

    test('正文带上这些事所属的事件名：去重、按任务顺序、全列不截断', () {
      // 同一个事件下三件今天到期的事 → 名字只出现一次；跨两个事件 → 两个都列。
      expect(
        digest(
          <String?>['2026-10-15', '2026-10-15', '2026-10-15'],
          events: <String>['备考', '健身', '备考'],
        )!.body,
        '今天有 3 件事到期：备考、健身',
      );
      // 不在今天到期的那条，它的事件名也不该被列进来（名字跟着任务走）。
      expect(
        digest(
          <String?>['2026-10-15', '2026-10-16'],
          events: <String>['备考', '明天的事'],
        )!.body,
        '今天有 1 件事到期：备考',
      );
    });

    test('事件删了 / 悬挂引用的那条只是不列名字，条数照数', () {
      expect(
        digest(
          <String?>['2026-10-15', '2026-10-15'],
          events: <String>['', '健身'],
        )!.body,
        '今天有 2 件事到期：健身',
      );
      expect(
        digest(<String?>['2026-10-15'], events: <String>['   '])!.body,
        '今天有 1 件事到期',
        reason: '全是空白的事件名等于没有',
      );
    });

    test('带时刻的不数进来 —— 那些走两档提前量，各催过一次了', () {
      expect(digest(<String?>['2026-10-15 09:00']), isNull);
      // 混着来：只数没时刻的那一条
      final mixed = digest(<String?>['2026-10-15 09:00', '2026-10-15']);
      expect(mixed!.body, '今天有 1 件事到期');
    });

    test('不是今天的都不数：明天、昨天、没排期、空串', () {
      expect(
        digest(<String?>['2026-10-16', '2026-10-14', null, '', '不是日期']),
        isNull,
      );
    });

    test('昨天到期的那条**不算今天的事**（不把逾期扩张进来）', () {
      // 这一条刻意与「已逾期」那一档划清界限：逾期有自己的去处（那三个列表），
      // 零点这句回答的是"今天要做什么"。
      expect(
        planDailyDigest(
          tasks: const <DailyDigestTask>[
            DailyDigestTask(dueAt: '2026-10-14'),
          ],
          now: noon,
        ),
        isNull,
      );
    });

    test('一条都没有 ⇒ 不排（零点固定响一声"今天没事"比不响更烦人）', () {
      expect(digest(const <String?>[]), isNull);
    });

    test('过了零点重排：`at` 仍是当天零点（补发由调用方决定）', () {
      // 这个函数是纯的：它不判断"错过"，只给出"哪一天的那一条"。
      expect(digest(<String?>['2026-10-15'], at: noon)!.at, DateTime(2026, 10, 15));
      // 跨过午夜那一秒之后，今天就是新的一天了 —— 旧那条自然不再算
      expect(digest(<String?>['2026-10-15'], at: DateTime(2026, 10, 16, 0, 1)), isNull);
    });

    test('与那两档同一个任务位不会撞：汇总固定用 slot 3', () {
      expect(digest(<String?>['2026-10-15'])!.slot, 3);
      expect(slotCatchUp, 2, reason: '补发占 2，汇总不能占它');
    });

    test('前一天的 now 不会把今天的算进来（按 now 的日期取今天）', () {
      expect(
        planDailyDigest(
          tasks: const <DailyDigestTask>[
            DailyDigestTask(dueAt: '2026-10-15'),
          ],
          now: DateTime(2026, 10, 14, 23, 59),
        ),
        isNull,
      );
    });
  });
}
