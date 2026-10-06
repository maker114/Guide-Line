import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/ui/common/pm24_time_picker.dart';

/// 自己画的表盘：**格位 → 几点**的映射（用户 2026-10-06："照着画一个"）。
///
/// 这一页里只有这条逻辑需要机器验证（画得对不对、点得准不准要真机看）：
/// 12 格表盘上"哪一格代表几点"，以及下午那半圈标 13–23。
void main() {
  test('上午：12 点方向是午夜（0），顺时针 1..11', () {
    expect(hourForDialIndex(0, pm: false), 0, reason: '12 点方向的"12"在上午就是 00:00');
    for (int i = 1; i <= 11; i++) {
      expect(hourForDialIndex(i, pm: false), i);
    }
  });

  test('下午：12 点方向是正午（12），顺时针 13..23', () {
    expect(hourForDialIndex(0, pm: true), 12, reason: '正午是 12:00，不是 0');
    for (int i = 1; i <= 11; i++) {
      expect(hourForDialIndex(i, pm: true), i + 12);
    }
  });

  test('标出来的字：上午 12 / 1..11，下午 12 / 13..23', () {
    expect(labelForDialIndex(0, pm: false), '12');
    expect(labelForDialIndex(0, pm: true), '12');
    expect(labelForDialIndex(3, pm: false), '3');
    expect(labelForDialIndex(3, pm: true), '15', reason: '这就是用户要的那件事');
    expect(labelForDialIndex(11, pm: true), '23');
  });

  test('分钟：每格 5 分钟，绕一圈', () {
    expect(minuteForDialIndex(0), 0);
    expect(minuteForDialIndex(1), 5);
    expect(minuteForDialIndex(11), 55);
    expect(minuteForDialIndex(12), 0, reason: '正好一圈回到 00');
  });

  testWidgets('表盘真的画出来了，并且上午/下午能点', (tester) async {
    TimeOfDay? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showPm24TimePicker(
                    context,
                    initial: const TimeOfDay(hour: 15, minute: 30),
                  );
                },
                child: const Text('开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();

    // 表头按 24 小时写；一进来是"选小时"
    expect(find.text('15:30'), findsOneWidget);
    expect(find.text('选小时'), findsOneWidget);
    expect(find.text('上午'), findsOneWidget);
    expect(find.text('下午'), findsOneWidget);

    // 点「上午」⇒ 表头跟着回到上午那一半（15 → 3）
    await tester.tap(find.text('上午'));
    await tester.pumpAndSettle();
    expect(find.text('03:30'), findsOneWidget);

    // 「完成」把结果交回去
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 3, minute: 30));
  });
}
