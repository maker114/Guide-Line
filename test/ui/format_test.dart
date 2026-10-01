import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/ui/common/format.dart';

/// 日期口径：列表与日期选择器都靠它显示，边界必须钉死。
///
/// 所有用例都传入固定的 `now`，否则会随"今天是几号"飘。
///
/// 改这条的目的（灵感 16）：**任何距离都要给得出"还剩几天"**。
/// 早先超过 7 天就退回「M月D日」，「还有 30 天」这种最有用的信息就没了。
void main() {
  final now = DateTime(2026, 9, 23);

  group('describeDate：相对口径', () {
    test('空值与空串给空串，解析不了的原样返回', () {
      expect(describeDate(null, now: now), '');
      expect(describeDate('', now: now), '');
      expect(describeDate('不是日期', now: now), '不是日期');
    });

    test('今天 / 明天 / 昨天', () {
      expect(describeDate('2026-09-23', now: now), '今天');
      expect(describeDate('2026-09-24', now: now), '明天');
      expect(describeDate('2026-09-22', now: now), '昨天');
    });

    test('逾期按天数累计', () {
      expect(describeDate('2026-09-21', now: now), '逾期 2 天');
      expect(describeDate('2020-01-01', now: now), '逾期 2457 天');
    });

    test('超过 7 天**也要给天数**（不再退回「M月D日」）', () {
      expect(describeDate('2026-09-30', now: now), '7 天后');
      expect(describeDate('2026-10-01', now: now), '8 天后', reason: '第 8 天必须仍是天数');
      expect(describeDate('2026-10-23', now: now), '30 天后');
      expect(describeDate('2027-09-23', now: now), '365 天后', reason: '跨年也算天数');
    });

    test('跨月与跨年按日历天算', () {
      expect(describeDate('2026-10-01', now: DateTime(2026, 9, 30)), '明天');
      expect(describeDate('2027-01-01', now: DateTime(2026, 12, 31)), '明天');
    });
  });

  group('describeDateWithDays：绝对日期 + 剩余天数', () {
    test('两者一起给，格式是「YYYY-MM-DD（相对日）」', () {
      expect(describeDateWithDays('2026-09-30', now: now), '2026-09-30（7 天后）');
      expect(describeDateWithDays('2026-09-23', now: now), '2026-09-23（今天）');
      expect(describeDateWithDays('2026-09-20', now: now), '2026-09-20（逾期 3 天）');
    });

    test('没有日期时给空串（调用方自己决定显示「未设置」）', () {
      expect(describeDateWithDays(null, now: now), '');
      expect(describeDateWithDays('', now: now), '');
    });

    test('解析不了时只回原文，不拼成重复的括号', () {
      expect(describeDateWithDays('2026-13-99', now: now), '2026-13-99');
      expect(describeDateWithDays('不是日期', now: now), '不是日期');
    });

    test('越界日期不会被"规范化"成另一个日子', () {
      // DateTime.tryParse 会把 13 月滚到次年 1 月、32 号滚到下月，
      // 于是脏值静默变成一个真实日期 —— 必须按原文挡掉。
      expect(parseIsoDate('2026-13-01'), isNull, reason: '13 月不存在');
      expect(parseIsoDate('2026-02-30'), isNull, reason: '2 月没有 30 号');
      expect(parseIsoDate('2026-04-31'), isNull, reason: '4 月只有 30 天');
      expect(parseIsoDate('2026-09-32'), isNull, reason: '9 月只有 30 天');
      expect(describeDate('2026-13-01', now: now), '2026-13-01', reason: '原样返回，不猜');
    });

    test('月日必须补零（避免同一日期两种写法）', () {
      expect(parseIsoDate('2026-09-23'), DateTime(2026, 9, 23));
      expect(parseIsoDate('2026-1-5'), isNull, reason: '要写成 2026-01-05');
      expect(parseIsoDate('2026-09-23T10:00'), isNull, reason: '只接受日期，不接受时间');
    });

    test('**不做 trim**：前后带空白一律拒绝（别把它悄悄放宽）', () {
      // 2026-10-01：把实现搬进 `Ids.parseIsoDate` 时我顺手加了 `value.trim()`，
      // 于是 `' 2026-09-23'` 从"拒绝"变成"接受"。这次改动是**收紧**，不该混进放宽。
      // 独立核验把这个偏差揪了出来，这条用例就是那次发现的落点。
      for (final padded in <String>[' 2026-09-23', '2026-09-23 ', '  2026-09-23  ', '\t2026-09-23']) {
        expect(
          parseIsoDate(padded),
          isNull,
          reason: '「$padded」带空白：旧实现拒绝，就不要让它变成接受',
        );
      }
      expect(parseIsoDate('2026-09-23'), DateTime(2026, 9, 23), reason: '干净的原串照收');
    });

    test('**年份补足 4 位**：0000~0999 的日期不能被误判成"不存在"', () {
      // 2026-10-01 的回归：旧实现有 `parsed.year.toString().padLeft(4, '0')`，
      // 我搬代码时漏了。少了它，`'0999-01-01'` 回格式化成 `'999-01-01'` ≠ 原文
      // → 判 null → `Canonical.readDate` 会**拒掉一个形态合法、日历上真实存在的日期**，
      // 还错报"日历上不存在"。核验指出这个方向是**单向**的（只有 0000~0999 受影响）。
      expect(parseIsoDate('0999-01-01'), DateTime(999, 1, 1), reason: '它是真实存在的一天');
      expect(parseIsoDate('0001-02-03'), DateTime(1, 2, 3));
      expect(parseIsoDate('9999-12-31'), DateTime(9999, 12, 31), reason: '上界也要能过');
    });
  });

  group('isOverdue 与 dateOffset', () {
    test('逾期严格早于今天，今天不算逾期', () {
      expect(isOverdue('2026-09-22', now: now), isTrue);
      expect(isOverdue('2026-09-23', now: now), isFalse);
      expect(isOverdue('2026-09-24', now: now), isFalse);
      expect(isOverdue(null, now: now), isFalse);
      expect(isOverdue('不是日期', now: now), isFalse);
    });

    test('dateOffset 会正确进位到相邻月份', () {
      expect(dateOffset(0, now: now), '2026-09-23');
      expect(dateOffset(7, now: now), '2026-09-30');
      expect(dateOffset(9, now: now), '2026-10-02', reason: '要进位到 10 月');
      expect(dateOffset(-1, now: now), '2026-09-22');
      expect(dateOffset(0, now: DateTime(2026, 12, 31)), '2026-12-31');
      expect(dateOffset(1, now: DateTime(2026, 12, 31)), '2027-01-01', reason: '要进位到下一年');
    });
  });
}
