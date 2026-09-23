import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/ui/common/urgency.dart';

/// 紧迫度分档：绿→红的色阶靠它决定，所以边界必须钉死。
///
/// 所有用例都传入固定的 `now`，否则会随"今天是几号"飘。
void main() {
  final now = DateTime(2026, 9, 23);

  group('紧迫度分档', () {
    test('没有到期日 → none（"没排期"要能与"还早"区分开）', () {
      expect(urgencyOf(null, now: now), Urgency.none);
      expect(urgencyOf('', now: now), Urgency.none);
      expect(urgencyOf('不是日期', now: now), Urgency.none);
    });

    test('昨天及更早 → overdue', () {
      expect(urgencyOf('2026-09-22', now: now), Urgency.overdue);
      expect(urgencyOf('2020-01-01', now: now), Urgency.overdue);
    });

    test('边界：今天 / 3 天内 / 一周内 / 一周以后', () {
      expect(urgencyOf('2026-09-23', now: now), Urgency.today);
      expect(urgencyOf('2026-09-24', now: now), Urgency.soon, reason: '明天');
      expect(urgencyOf('2026-09-25', now: now), Urgency.soon, reason: '第 2 天是 soon 的上界');
      expect(urgencyOf('2026-09-26', now: now), Urgency.week, reason: '第 3 天进 week');
      expect(urgencyOf('2026-09-30', now: now), Urgency.week, reason: '第 7 天仍是 week');
      expect(urgencyOf('2026-10-01', now: now), Urgency.later, reason: '第 8 天离开 week');
    });

    test('跨月与跨年也算得对（按日历天而不是按毫秒）', () {
      expect(urgencyOf('2026-10-01', now: DateTime(2026, 9, 30)), Urgency.soon);
      expect(urgencyOf('2027-01-01', now: DateTime(2026, 12, 31)), Urgency.soon);
    });

    test('分档顺序就是紧迫程度：逾期最靠前、没排期最后', () {
      expect(urgencyRank(Urgency.overdue), lessThan(urgencyRank(Urgency.today)));
      expect(urgencyRank(Urgency.today), lessThan(urgencyRank(Urgency.soon)));
      expect(urgencyRank(Urgency.soon), lessThan(urgencyRank(Urgency.week)));
      expect(urgencyRank(Urgency.week), lessThan(urgencyRank(Urgency.later)));
      expect(urgencyRank(Urgency.later), lessThan(urgencyRank(Urgency.none)));
    });

    test('每一档都有中文标签（分组头直接用它）', () {
      for (final urgency in Urgency.values) {
        expect(urgencyLabel(urgency), isNotEmpty);
      }
      expect(urgencyLabel(Urgency.overdue), '已逾期');
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
