import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/rules/reminder_schedule.dart';

/// 平台适配层：**本地提醒**（ADR-097）。
///
/// 为什么这是"本地"的：调度交给系统的 `AlarmManager`，不经任何服务器、
/// 不走 FCM —— 所以 README 里"推送提醒：FCM 在大陆不可用"那条理由对它不成立。
///
/// **只在 Android 上真的做事**（用户 2026-10-03 定："电脑不需要提醒"）。
/// 其它平台上每个方法都是空操作，绝不抛错 —— 与 [FileDurabilityPlatform] 同一条口径。
///
/// 真机实测（小米 15 Pro / HyperOS / Android 16，2026-10-03）钉下的三条：
///
/// | 事项 | 结论 |
/// |---|---|
/// | 精确闹钟 | `USE_EXACT_ALARM` **声明即生效**、不弹权限框，实测偏差 1~4 秒 |
/// | 重启后重排 | **需要用户在系统设置里给本应用开「自启动」** —— 不开的话 HyperOS 的 `BroadcastQueueInjector` 会以 `process is not permitted to auto start` 把开机广播丢掉，闹钟照响、广播照发，然后**静默消失** |
/// | 时区 | 不引设备时区名：把 `due_at` 那串"本地墙上时间"算成**绝对时刻**、用 [tz.UTC] 表达即可 —— 闹钟只认绝对时刻 |
///
/// [tz.UTC] 是内置的（不读时区数据库），所以这里**不调** `initializeTimeZones()`：
/// 提醒默认是关的，没打开的人不该为一个用不上的功能付启动开销。
class NotificationService {
  NotificationService._();

  /// 全局单例：插件本身也是单例，多份实例只会让"谁初始化过了"变得不清楚。
  static final NotificationService instance = NotificationService._();

  /// 通知渠道 id / 名字。渠道是**系统侧**的概念，改 id 等于换一条新渠道
  /// （老渠道会留在系统设置里），所以它是**契约**的一部分，不许随手改。
  static const String channelId = 'guideline_reminder';
  static const String channelName = '任务提醒';
  static const String channelDescription =
      '任务到期之前的提醒。可以在「更多 → 提醒」里改提前量，或整个关掉。';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  bool _ready = false;
  void Function(String taskId)? _onTap;

  /// 电脑端不做提醒。界面靠它决定显不显示那两格设置。
  bool get supported => Platform.isAndroid;

  /// 接一次就行；`onTap` 可以在之后再给（会覆盖上一次的）。
  ///
  /// 冷启动与热启动两条路都要接：热启动走这里的回调，
  /// 冷启动那次拿不到回调，得靠 [takeLaunchPayload] 主动问。
  Future<void> initialize({void Function(String taskId)? onTap}) async {
    if (onTap != null) _onTap = onTap;
    if (!supported || _ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        _onTap?.call(payload);
      },
    );
    _ready = true;
  }

  /// 系统通知权限开着没有。**读不到就当"没开"** —— 宁可多提示一次，
  /// 也不要谎报"已经能提醒了"。
  Future<bool> notificationsEnabled() async {
    if (!supported) return false;
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? false;
  }

  /// 申请通知权限（Android 13+ 才有这一步）。返回申请后的状态。
  Future<bool> requestPermission() async {
    if (!supported) return false;
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? false;
  }

  /// **全撤 + 重排**：把当前应该挂着的提醒换成一整份 [fires]。
  ///
  /// 为什么是"全撤再重排"而不是"增量对齐"：增量要自己维护一套"系统里现在挂着什么"
  /// 的镜像，那份镜像一旦与真实状态漂开，就变成"该弹的不弹 / 删了的还在弹"，
  /// 而且查起来毫无线索。全撤重排是**幂等**的 —— 同一份计划算多少遍结果都一样，
  /// 所以它可以在每次数据变动之后无脑跑一遍。
  ///
  /// （通知 id 是"任务 + 档位"算出来的稳定值，见 [notificationIdFor]，
  /// 这也是撤销能撤干净的前提。）
  Future<void> replaceAll(List<ReminderFire> fires) async {
    if (!supported) return;
    await initialize();
    await _plugin.cancelAllPendingNotifications();
    for (final fire in fires) {
      await _plugin.zonedSchedule(
        id: notificationIdFor(fire.taskId, fire.slot),
        title: fire.title,
        body: fire.body,
        // 把"本地墙上时间"算出来的绝对时刻换个说法表达 —— 闹钟只认这个。
        scheduledDate: tz.TZDateTime.from(fire.at, tz.UTC),
        notificationDetails: _details(),
        // 到点必须准：实测这条在 HyperOS 上偏差 1~4 秒。
        // 精确闹钟权限靠清单里的 `USE_EXACT_ALARM`（声明即生效，不问用户）。
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: fire.taskId,
      );
    }
  }

  /// 立刻弹一条（"错过窗口"补的那一条）。走 `show` 而不是排一个"现在"的期，
  /// 因为排期有可能被系统延后，而补发的语义就是"现在就告诉你"。
  Future<void> showNow(ReminderFire fire) async {
    if (!supported) return;
    await initialize();
    await _plugin.show(
      id: notificationIdFor(fire.taskId, fire.slot),
      title: fire.title,
      body: fire.body,
      notificationDetails: _details(),
      payload: fire.taskId,
    );
  }

  /// 把还没到点的排期全撤掉。关掉总开关时用。
  Future<void> cancelAllPending() async {
    if (!supported) return;
    await initialize();
    await _plugin.cancelAllPendingNotifications();
  }

  /// 冷启动那一次：这次启动是不是"用户点了通知"进来的？是的话给出那条任务 id。
  ///
  /// 只问一次就够（上层拿到之后自己清掉），因为冷启动只有一次。
  Future<String?> takeLaunchPayload() async {
    if (!supported) return null;
    await initialize();
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final payload = details?.notificationResponse?.payload;
    if (payload == null || payload.isEmpty) return null;
    return payload;
  }

  /// `Importance.high`（而不是 `max`）：提醒要能弹横幅、要出声，
  /// 但 `max` 那一档是留给"闹钟级"的，用在任务提醒上反而容易被用户在系统里整条屏蔽。
  NotificationDetails _details() => const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
}
