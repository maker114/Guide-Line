import '../ids.dart';
import '../models/reminder.dart';

/// 一条**该在什么时候弹、弹什么**的提醒（纯值，不含任何平台概念）。
class ReminderFire {
  const ReminderFire({
    required this.taskId,
    required this.slot,
    required this.at,
    required this.title,
    required this.body,
  });

  /// 这条提醒属于哪个任务（点开时靠它回到那条任务所在的事件）。
  final String taskId;

  /// 第几档：`0` / `1` 是 [ReminderLead] 的两档，[slotCatchUp] 是补发那一条。
  ///
  /// 它同时是通知 id 的一半（见 [notificationIdFor]）——
  /// 同一个任务的同一条档位**永远是同一个 id**，所以重排是"覆盖"而不是"堆叠"。
  final int slot;

  /// 预定时刻（**本地墙上时间解释出来的绝对时刻**）。
  final DateTime at;

  /// 通知标题：任务标题。
  final String title;

  /// 通知正文：事件名 + 还剩多久。
  final String body;

  @override
  String toString() => 'ReminderFire(slot=$slot, at=$at, $title / $body)';
}

/// 一条任务算出来的提醒计划。
class ReminderPlan {
  const ReminderPlan({this.fires = const <ReminderFire>[], this.catchUp});

  /// **还在未来**的提醒点，按时间升序。交给平台层去排。
  final List<ReminderFire> fires;

  /// 需要**立刻补**的那一条（至多一条，`null` = 不用补）。
  ///
  /// 与 [fires] 分开，是因为两者的**触发时机不同**：这个由"用户刚建/刚改了这条任务"
  /// 这一个动作驱动，弹完就完了；而 [fires] 由重排过程管理、每次都会被重算。
  /// 混在一起会让"重排"顺手把补发也重放一遍 —— 那就成了每次改点别的东西都弹一次。
  final ReminderFire? catchUp;

  bool get isEmpty => fires.isEmpty && catchUp == null;
}

/// 补发那一条占用的档位号（与两档分开，免得覆盖正在排的那一条）。
const int slotCatchUp = 2;

/// 「今日事」那一条占用的档位号（同样与两档分开）。
const int slotDailyDigest = 3;

/// 「今日事」通知的**任务位**：它是**一条汇总**，不属于任何一条任务。
///
/// 为什么能固定成一个字面量：通知 id 是"任务位 + 档位"哈希出来的
/// （见 [notificationIdFor]），而这条永远是同一条，不存在"两条汇总互相覆盖"。
///
/// 为什么不是一个真实任务 id：这个字面量**不能长得像 UUID** ——
/// `AppController` 拿通知回带的 payload 去查任务，查不到就不跳页；
/// 万一将来有人把它当成一条真任务去 `findTask`，这里要一眼看出它不是一个 id。
const String dailyDigestTaskId = 'daily-digest';

/// 「今日事」的一条输入：一个任务的到期值，加上它所属事件的名字。
///
/// 为什么要带事件名进来：通知正文要说清"今天到期的是哪几条线的事"
/// （用户 2026-10-29 要求："提醒当天的事件时，需要在通知里附上事件名称"）。
/// 这个函数是**纯的** —— 事件名只能由调用方先查库、再随任务一起传进来。
class DailyDigestTask {
  const DailyDigestTask({required this.dueAt, this.eventName = ''});

  /// 任务的 `due_at`：只有「日期」、没有时刻的那一类才会进汇总。
  final String? dueAt;

  /// 所属事件的名字。查不到（悬挂引用 / 事件已删）时是空串，正文里就不列它。
  final String eventName;
}

/// 一条「今日事」通知：**到期日就是今天、而没设具体时刻**的任务有几条。
///
/// 口径（用户 2026-10-15 定）："没有设置准确时间时在当天早上零点发消息表示今日事件"。
///
/// 正文（用户 2026-10-29 加）：`今天有 N 件事到期：事件甲、事件乙` ——
/// 事件名**去重、保持输入顺序、全列不截断**；一条事件名都查不到时退回原句
/// `今天有 N 件事到期`，不硬凑一个空冒号。
///
/// ```
/// due_at 落在今天
///   ├─ 一条都没有 ────────────────────────────► 不排（不打扰）
///   └─ 有 N 条
///         ├─ 今天零点还在未来 ────────────────► 排进 fires（零点那一下到点）
///         └─ 今天零点已经过去 ────────────────► 交回调用方立刻补发（见下）
/// ```
///
/// 三条边界，都与 [planTaskReminders] 那条"只提醒设了具体时间的"**并行**、
/// 互不改写（ADR-097 那条一个字不动）：
///
///   · **带时刻的不算**：「今日事」回答的是"今天有哪些事到期"，而带时刻的那些
///     已经由两档提前量各催过一次（`10-03 18:00` 会在 17:00 / 17:50 各响一次）；
///     把它们再数进零点那条，只会让人以为今天多出几件事；
///   · **只到天**：`due_at` 就是今天那一个日期串，不做"逾期也算"的扩张 ——
///     逾期的任务属于「已逾期」那一档，不属于"今天要做"；
///   · **一条都没有就不排**：零点固定响一声"今天没事"，比不响更烦人。
///
/// 补发交给调用方（返回的 `at` 是**零点**，它已经过去时调
/// `NotificationService.showNow` 立刻弹一条）：这样这个函数是纯的，
/// "什么时候算错过"那套记账仍旧只有 `AppController` 一处。
///
/// 这一条整体记在 **ADR-099**：它是"与那两档并列的第三条通知"，不是第三档。
ReminderFire? planDailyDigest({
  required Iterable<DailyDigestTask> tasks,
  required DateTime now,
}) {
  final today = Ids.todayDate(now);
  var count = 0;
  // 事件名按**任务顺序**去重收进来：同一个事件下有三件今天到期的事，
  // 正文里只该出现一次这个事件的名字（否则一行里重复三遍，反而看不清有哪几条线）。
  final eventNames = <String>[];
  for (final task in tasks) {
    final due = task.dueAt;
    // 带时刻的不算（见上）；`due` 为 `null` 或空串自然也被这一条挡掉
    if (due == null || Ids.hasTimeOfDay(due)) continue;
    if (due != today) continue;
    count += 1;
    final name = task.eventName.trim();
    if (name.isNotEmpty && !eventNames.contains(name)) eventNames.add(name);
  }
  if (count == 0) return null;

  return ReminderFire(
    taskId: dailyDigestTaskId,
    slot: slotDailyDigest,
    // 本地零点：与 `due_at` 同一套"本地墙上时间"的解释（闹钟只认绝对时刻，
    // 换算在平台层做，见 `notification_service.dart`）
    at: DateTime(now.year, now.month, now.day),
    title: '今日事',
    body: _dailyDigestBody(count, eventNames),
  );
}

/// 「今日事」的正文：条数是主体，事件名接在后面。
///
/// `今天有 3 件事到期：备考、健身`；一条事件名都没有时就只说前半句。
/// 用**全角冒号 + 顿号**：与界面里其它「A：B」句式、以及事件名的中文习惯一致。
String _dailyDigestBody(int count, List<String> eventNames) {
  final head = '今天有 $count 件事到期';
  if (eventNames.isEmpty) return head;
  return '$head：${eventNames.join('、')}';
}

/// 算一条任务该排哪些提醒。
///
/// 口径（用户 2026-10-03 定，逐条都有守卫用例）：
///
/// ```
/// 任务到 due_at
///   ├─ 不开着（已完成 / 已搁置 / 已归档）──────► 一条都不排
///   ├─ due_at 只有日期、没有时刻 ──────────────► 一条都不排（用户："只提醒设置了具体时间的"）
///   └─ due_at = "YYYY-MM-DD HH:mm"
///         ├─ 已经到期 / 逾期 ─────────────────► 一条都不排（不再补，逾期不提醒）
///         └─ 还没到期
///               ├─ 到点还在未来的档 ──────────► 排进 fires
///               └─ 到点已经过去的档 ──────────► 不单独排，合成一条 catchUp
/// ```
///
/// 为什么"错过的档"合成一条而不是每档补一条：用户原话是"合并成一条" ——
/// 一条任务在通知栏里炸出两三条同义通知，比漏一条更烦人。
///
/// ⚠️ 这一条**只管"到期之前的两档"**。2026-10-15 起的「今日事」
/// （[planDailyDigest]）是**并列的另一条**，不动这里的任何一条判据 ——
/// 尤其是"只有日期、没有时刻 ⇒ 永不提醒"那句，它守的是"别给某天编一个钟点"，
/// 而零点那条说的是"今天要做哪些"，两件事不冲突。
///
/// **不做**的事（说清楚免得以后当缺陷查）：这里只按"现在"算一遍。
/// "App 一直没运行、某个档在关机期间过去了"那种补发要靠跨启动记账，
/// 本轮不做 —— 真机上验过：开机时系统会把还没投递的那几条补上（见 `CHANGELOG` 2.7.0）。
ReminderPlan planTaskReminders({
  required String taskId,
  required String taskTitle,
  required String eventName,
  required String? dueAt,
  required bool open,
  required List<ReminderLead> leads,
  required DateTime now,
}) {
  if (!open) return const ReminderPlan();
  // 只有日期没有时刻 ⇒ 永不提醒。这是本轮最硬的一条边界：
  // 给"某天要做"编一个具体钟点是编出来的信息，而用户明确只要"具体时间"那一类。
  if (!Ids.hasTimeOfDay(dueAt)) return const ReminderPlan();
  final due = Ids.parseIsoDateTime(dueAt);
  if (due == null) return const ReminderPlan();
  // 到期那一刻及以后不再提醒（含已逾期）：提醒的用途是"别忘了"，
  // 而一件事已经到点了再来催，只会变成噪音。
  if (!due.isAfter(now)) return const ReminderPlan();

  final fires = <ReminderFire>[];
  var missed = false;

  for (var slot = 0; slot < leads.length; slot++) {
    final lead = leads[slot];
    if (!lead.enabled) continue;
    final at = due.subtract(Duration(minutes: lead.minutes));
    if (at.isAfter(now)) {
      fires.add(ReminderFire(
        taskId: taskId,
        slot: slot,
        at: at,
        title: taskTitle,
        body: _body(eventName, lead.minutes),
      ));
    } else {
      // 这一档的到点已经过去 —— 不排它，只记一笔"有档被错过了"。
      missed = true;
    }
  }

  fires.sort((a, b) => a.at.compareTo(b.at));

  if (!missed) return ReminderPlan(fires: fires);

  // 补发那一条说的是**真实的剩余时间**（不是那一档原本的提前量）：
  // 提前 1 小时那档错过了，现在只剩 25 分钟，就该说"还有 25 分钟到期"。
  final remaining = due.difference(now);
  return ReminderPlan(
    fires: fires,
    catchUp: ReminderFire(
      taskId: taskId,
      slot: slotCatchUp,
      at: now,
      title: taskTitle,
      body: _body(eventName, _ceilMinutes(remaining)),
    ),
  );
}

/// 通知 id：**同一个任务的同一档永远是同一个数**。
///
/// 为什么必须稳定：重排是"先全部撤掉、再按计划排一遍"（幂等），
/// 如果 id 每次都变，撤销就撤不干净、旧排期会留着继续弹。
///
/// 为什么可以哈希：任务 id 是 UUID，通知 id 却必须是 32 位整数（平台限制）。
/// 取 28 位再乘 4 加档位号，上界约 2³⁰ 不会溢出成负数。
/// 哈希碰撞的代价是"两条任务共用一个通知 id"⇒ 后者顶掉前者（漏一条提醒）；
/// 按本应用的数据规模（几百条任务）冲突概率在 10⁻⁶ 量级，可以接受 ——
/// 真要彻底避免，得维护一张持久的"任务 id → 通知 id"映射表，
/// 那份状态本身又会成为新的出错来源，不划算。
int notificationIdFor(String taskId, int slot) {
  var hash = 0x811c9dc5; // FNV-1a 32 位
  for (final unit in taskId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return ((hash & 0x0FFFFFFF) * 4) + slot;
}

/// 正文：`事件名 · 还有 1 小时到期`；不知道事件名时只留后半句。
String _body(String eventName, int minutes) {
  final tail = '还有 ${describeLeadMinutes(minutes)}到期';
  final name = eventName.trim();
  return name.isEmpty ? tail : '$name · $tail';
}

/// 把"多少分钟"说成人话：`1 小时` / `1 小时 30 分钟` / `10 分钟` / `2 天`。
///
/// 为什么要它：设置页上那两档是数字（60 / 10），而通知正文是给人看的句子。
/// 两处必须**同一套说法**，否则设置里写 60、通知里说"1 小时"，用户会怀疑配错了。
String describeLeadMinutes(int minutes) {
  if (minutes >= 1440 && minutes % 1440 == 0) {
    return '${minutes ~/ 1440} 天';
  }
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分钟';
  }
  return '$minutes 分钟';
}

/// 剩余时间往上取整到分钟：`25 分 30 秒` ⇒ `26 分钟`。
///
/// 往上取整而不是四舍五入，是为了**不把"还剩不到 1 分钟"说成"还有 0 分钟"** ——
/// 后者读起来像已经到期了。
int _ceilMinutes(Duration remaining) {
  final seconds = remaining.inSeconds;
  if (seconds <= 0) return 0;
  return (seconds + 59) ~/ 60;
}
