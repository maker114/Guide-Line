import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/ui_prefs.dart';

/// 提醒的"已补发过"标记（`reminderCatchUpShown`）的落盘管道。
///
/// ## 为什么这条守卫存在（2026-10-06）
///
/// 用户实机反馈："当一件事情的截止日期进入一个小时之内时，每当我打开一次软件
/// 就会弹一次通知。" 根因是补发去重集合只活在 `AppController` 的内存里，
/// **每次重开 App 就是个新控制器** ⇒ 同一档被反复补发。
///
/// 修法是把去重键落进偏好文件。这条用例守的是**管道**那一段：
/// 写得出、读得回、老文件不炸。
///
/// ⚠️ **端到端那一格钉不住**：`AppController._refreshRemindersOnce` 在
/// `NotificationService.supported == false` 时直接 return（测试宿主正是如此），
/// 而那个服务是单例、没有注入口 —— 所以"只弹一次"这件事目前**只有真机能验**。
/// 要让它变成机器守卫，得先给 `NotificationService` 加一个可注入的委托，
/// 那是另一件事（记在 `docs/开发节奏.md` 的待办口径里）。
void main() {
  test('已补发的标记能落盘、能读回（这次的持久化管道）', () {
    final prefs = UiPrefs.empty.copyWith(
      reminderCatchUpShown: <String>{'task-a|2026-10-06 18:00', 'task-b|2026-10-07'},
    );

    final reloaded = UiPrefs.fromJson(prefs.toJson());

    expect(reloaded.reminderCatchUpShown, prefs.reminderCatchUpShown);
    expect(reloaded.toCanonicalText(), prefs.toCanonicalText());
  });

  test('同样的内容两次序列化逐字节一致（集合要先排序）', () {
    // `Set` 的迭代顺序不稳定：不排序的话，"内容没变"也会写出不同的字节，
    // 于是每次重排提醒都白白重写一遍偏好文件。
    final a = UiPrefs.empty.copyWith(
      reminderCatchUpShown: <String>{'x|1', 'y|2', 'z|3'},
    );
    final b = UiPrefs.empty.copyWith(
      reminderCatchUpShown: <String>{'z|3', 'x|1', 'y|2'},
    );

    expect(a.toCanonicalText(), b.toCanonicalText());
  });

  test('老偏好文件没有这个键 ⇒ 空集（不会因此少补发什么）', () {
    final json = UiPrefs.empty.toJson()..remove('reminderCatchUpShown');

    expect(UiPrefs.fromJson(json).reminderCatchUpShown, isEmpty);
  });

  test('坏值只丢那一项，不整份重置', () {
    final json = UiPrefs.empty.toJson()
      ..['reminderCatchUpShown'] = <Object?>['ok|1', 42, '', null, 'also-ok|2'];

    expect(
      UiPrefs.fromJson(json).reminderCatchUpShown,
      <String>{'ok|1', 'also-ok|2'},
    );
  });

  // -------------------------------------------------------------- 今日事（2026-10-15）
  //
  // 与上面那条补发标记同一个理由、同一套管道（ADR-099）：**去重键必须落盘**，
  // 否则"同一天重开一次 App 就再弹一次今日事"——这正是 2026-10-06 那次
  // "每打开一次软件就弹一次通知"的翻版。形状照抄上面四条：往返、逐字节、
  // 老文件、坏值。
  group('今日事（dailyDigestEnabled / dailyDigestShown）', () {
    test('开关与"已弹过的日期"能落盘、能读回', () {
      final prefs = UiPrefs.empty.copyWith(
        dailyDigestEnabled: true,
        dailyDigestShown: <String>{'2026-10-15'},
      );

      final reloaded = UiPrefs.fromJson(prefs.toJson());

      expect(reloaded.dailyDigestEnabled, isTrue);
      expect(reloaded.dailyDigestShown, <String>{'2026-10-15'});
      expect(reloaded.toCanonicalText(), prefs.toCanonicalText());
    });

    test('同样的内容两次序列化逐字节一致（集合要先排序）', () {
      final a = UiPrefs.empty.copyWith(
        dailyDigestShown: <String>{'2026-10-15', '2026-10-16'},
      );
      final b = UiPrefs.empty.copyWith(
        dailyDigestShown: <String>{'2026-10-16', '2026-10-15'},
      );

      expect(a.toCanonicalText(), b.toCanonicalText());
    });

    test('老偏好文件两个键都没有 ⇒ 关着、且没弹过任何一天', () {
      final json = UiPrefs.empty.toJson()
        ..remove('dailyDigestEnabled')
        ..remove('dailyDigestShown');

      final prefs = UiPrefs.fromJson(json);

      expect(prefs.dailyDigestEnabled, isFalse, reason: '不该凭空开始每天零点弹一条');
      expect(prefs.dailyDigestShown, isEmpty);
    });

    test('开关缺键即关：写成别的值也不算开', () {
      expect(UiPrefs.fromJson(<String, dynamic>{'dailyDigestEnabled': 'yes'})
          .dailyDigestEnabled, isFalse);
      expect(UiPrefs.fromJson(<String, dynamic>{'dailyDigestEnabled': 1})
          .dailyDigestEnabled, isFalse);
    });

    test('坏值只丢那一项（复用 _readIdSet）', () {
      final json = UiPrefs.empty.toJson()
        ..['dailyDigestShown'] = <Object?>['2026-10-15', 42, '', null];

      expect(UiPrefs.fromJson(json).dailyDigestShown, <String>{'2026-10-15'});
    });

    test('与总开关互不隶属：关掉今日事不动总开关，反之亦然', () {
      final both = UiPrefs.empty.copyWith(
        reminderEnabled: true,
        dailyDigestEnabled: true,
      );

      final onlyLeads = both.copyWith(dailyDigestEnabled: false);
      expect(onlyLeads.reminderEnabled, isTrue);
      expect(onlyLeads.dailyDigestEnabled, isFalse);

      final onlyDigest = both.copyWith(reminderEnabled: false);
      expect(onlyDigest.reminderEnabled, isFalse);
      expect(onlyDigest.dailyDigestEnabled, isTrue);
    });
  });
}
