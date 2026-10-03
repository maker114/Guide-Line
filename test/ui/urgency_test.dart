import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/ui/common/urgency.dart';

/// 紧迫度分档：绿→红的色阶靠它决定，所以边界必须钉死。
///
/// 所有用例都传入固定的 `now`，否则会随"今天是几号"飘。
///
/// 这一档的**标签与判据必须对得上**：写「3 天内」就要覆盖到第 3 天
/// （早期版本判据是 `days <= 2`，标签却写「3 天内」，下面第一条用例专门钉这个）。
void main() {
  final now = DateTime(2026, 9, 23);

  group('紧迫度分档', () {
    test('没有到期日 → none（"没排期"要能与"还早"区分开）', () {
      expect(urgencyOf(null, now: now), Urgency.none);
      expect(urgencyOf('', now: now), Urgency.none);
      expect(urgencyOf('不是日期', now: now), Urgency.none);
    });

    test('昨天及更早 → overdue（逾期单独一档，不与今天合并）', () {
      expect(urgencyOf('2026-09-22', now: now), Urgency.overdue);
      expect(urgencyOf('2020-01-01', now: now), Urgency.overdue);
    });

    test('带 HH:mm 的截止时间**照样分档**，不因多一段时刻就掉进"没有到期日"', () {
      // 2026-10-02 的坑：这一处原来用 `Ids.parseIsoDate`，而它只认纯日期 ——
      // `'2026-09-24 08:30'` 会被判 null、返回 `Urgency.none`，
      // 于是设了钟点的任务**静默掉进「没有到期日」那一组**（分组、配色一起错）。
      expect(urgencyOf('2026-09-23 08:30', now: now), Urgency.today);
      expect(urgencyOf('2026-09-24 08:30', now: now), Urgency.within3);
      expect(urgencyOf('2026-09-22 23:59', now: now), Urgency.overdue);
      expect(
        urgencyOf('2026-09-23 23:59', now: now),
        Urgency.today,
        reason: '当天任何时刻都还是「今天」—— 逾期只按天算',
      );
    });

    test('边界：今天 / 3 天内 / 5 天内 / 7 天内 / 7 天后', () {
      expect(urgencyOf('2026-09-23', now: now), Urgency.today);
      expect(urgencyOf('2026-09-24', now: now), Urgency.within3, reason: '第 1 天');
      expect(urgencyOf('2026-09-26', now: now), Urgency.within3, reason: '第 3 天是 within3 的上界');
      expect(urgencyOf('2026-09-27', now: now), Urgency.within5, reason: '第 4 天进 within5');
      expect(urgencyOf('2026-09-28', now: now), Urgency.within5, reason: '第 5 天是 within5 的上界');
      expect(urgencyOf('2026-09-29', now: now), Urgency.within7, reason: '第 6 天进 within7');
      expect(urgencyOf('2026-09-30', now: now), Urgency.within7, reason: '第 7 天是 within7 的上界');
      expect(urgencyOf('2026-10-01', now: now), Urgency.later, reason: '第 8 天离开 within7');
    });

    test('跨月与跨年也算得对（按日历天而不是按毫秒）', () {
      // 9-30 → 10-01 是第 1 天
      expect(urgencyOf('2026-10-01', now: DateTime(2026, 9, 30)), Urgency.within3);
      // 12-31 → 01-01 是第 1 天
      expect(urgencyOf('2027-01-01', now: DateTime(2026, 12, 31)), Urgency.within3);
      // 跨年但落到第 7 天这一档
      expect(urgencyOf('2027-01-07', now: DateTime(2026, 12, 31)), Urgency.within7);
      expect(urgencyOf('2027-01-08', now: DateTime(2026, 12, 31)), Urgency.later);
    });

    test('分档顺序就是紧迫程度：逾期最靠前、没排期最后', () {
      expect(urgencyRank(Urgency.overdue), lessThan(urgencyRank(Urgency.today)));
      expect(urgencyRank(Urgency.today), lessThan(urgencyRank(Urgency.within3)));
      expect(urgencyRank(Urgency.within3), lessThan(urgencyRank(Urgency.within5)));
      expect(urgencyRank(Urgency.within5), lessThan(urgencyRank(Urgency.within7)));
      expect(urgencyRank(Urgency.within7), lessThan(urgencyRank(Urgency.later)));
      expect(urgencyRank(Urgency.later), lessThan(urgencyRank(Urgency.none)));
    });

    test('每一档都有中文标签（分组头直接用它），且标签与判据一致', () {
      for (final urgency in Urgency.values) {
        expect(urgencyLabel(urgency), isNotEmpty);
      }
      expect(urgencyLabel(Urgency.overdue), '已逾期');
      expect(urgencyLabel(Urgency.today), '今天');
      expect(urgencyLabel(Urgency.within3), '3 天内');
      expect(urgencyLabel(Urgency.within5), '5 天内');
      expect(urgencyLabel(Urgency.within7), '7 天内');
      expect(urgencyLabel(Urgency.later), '7 天后');
      expect(urgencyLabel(Urgency.none), '没有到期日');
    });
  });

  group('紧迫度配色', () {
    test('浅色与深色两套都覆盖了全部档位，且没有重复用色', () {
      for (final colors in <UrgencyColors>[UrgencyColors.light, UrgencyColors.dark]) {
        final used = <Color>{};
        for (final urgency in Urgency.values) {
          used.add(colors.of(urgency));
        }
        expect(used.length, Urgency.values.length, reason: '每档都该有自己的颜色');
      }
    });

    test('越接近越"热"：逾期比当天红，当天比 7 天后红', () {
      // 只比"红分量"这一个不变量，避免把具体色值钉死（色值属修订位，随时可调）
      int redness(Color c) => (c.r * 255).round() - (c.g * 255).round();
      final light = UrgencyColors.light;
      expect(redness(light.overdue), greaterThan(redness(light.later)));
      expect(redness(light.today), greaterThan(redness(light.within7)));
      expect(redness(light.within5), greaterThan(redness(light.later)));
    });

    test('lerp 在两端之间过渡（主题切换动画要用）', () {
      final mid = UrgencyColors.light.lerp(UrgencyColors.dark, 0.5);
      expect(mid.of(Urgency.overdue), isNot(UrgencyColors.light.of(Urgency.overdue)));
      expect(
        UrgencyColors.light.lerp(UrgencyColors.dark, 0).of(Urgency.later),
        UrgencyColors.light.of(Urgency.later),
      );
    });
  });
}
