import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/core/store/ui_prefs.dart';

/// 界面偏好的纯逻辑：默认值、JSON 往返、坏值收回。
///
/// 为什么值得单独测：`copyWith` 是**手写字段列表**，漏一个字段就会静默丢掉用户的设置
/// （比如改个折叠状态，把挑好的主题弄没了）。下面用一例把这条钉死。
void main() {
  group('默认值', () {
    test('默认主题、没有背景图、不透明度为约定值', () {
      const prefs = UiPrefs.empty;
      expect(prefs.themeId, UiPrefs.defaultThemeId);
      expect(prefs.backgroundImagePath, isNull);
      expect(prefs.backgroundSeedHex, isNull);
      expect(prefs.backgroundOpacity, UiPrefs.defaultBackgroundOpacity);
      expect(prefs.backgroundBlur, 0);
      expect(prefs.hasBackground, isFalse);
    });

    test('路径为空串也算没有背景图（不能拿空串去读文件）', () {
      expect(const UiPrefs(backgroundImagePath: '').hasBackground, isFalse);
    });
  });

  group('JSON 往返', () {
    test('所有字段都能原样读回', () {
      const original = UiPrefs(
        collapsedIds: <String>{'a', 'b'},
        lastTabIndex: 3,
        compactTaskView: true,
        lastExportedAt: 1788652800000,
        themeId: 'plum',
        backgroundImagePath: '/data/x/background.img',
        backgroundOpacity: 0.42,
        backgroundBlur: 8,
        backgroundSeedHex: '#7b3fa0',
      );

      final restored = UiPrefs.fromJson(original.toJson());

      expect(restored.collapsedIds, <String>{'a', 'b'});
      expect(restored.lastTabIndex, 3);
      expect(restored.compactTaskView, isTrue);
      expect(restored.lastExportedAt, 1788652800000);
      expect(restored.themeId, 'plum');
      expect(restored.backgroundImagePath, '/data/x/background.img');
      expect(restored.backgroundOpacity, 0.42);
      expect(restored.backgroundBlur, 8);
      expect(restored.backgroundSeedHex, '#7b3fa0');
      expect(restored.hasBackground, isTrue);
    });

    test('坏值被收回而不是照单全收', () {
      final restored = UiPrefs.fromJson(<String, dynamic>{
        'themeId': '', // 空 → 默认主题
        'backgroundOpacity': 7.5, // 越界 → 夹到 1
        'backgroundBlur': -3, // 负数 → 回默认
        'backgroundSeedHex': 'nope', // 形态不对 → 忽略
      });

      expect(restored.themeId, UiPrefs.defaultThemeId);
      expect(restored.backgroundOpacity, 1.0);
      expect(restored.backgroundBlur, 0);
      expect(restored.backgroundSeedHex, isNull);
    });

    test('老版本偏好（没有外观字段）能读，不会崩', () {
      final restored = UiPrefs.fromJson(<String, dynamic>{
        'collapsedIds': <dynamic>['x'],
        'lastTabIndex': 2,
      });

      expect(restored.collapsedIds, <String>{'x'});
      expect(restored.lastTabIndex, 2);
      expect(restored.themeId, UiPrefs.defaultThemeId);
      expect(restored.hasBackground, isFalse);
    });
  });

  group('AI 总开关', () {
    test('默认是开着的', () {
      expect(UiPrefs.empty.aiEnabled, isTrue);
    });

    test('关掉之后 JSON 往返还记得住', () {
      const original = UiPrefs(aiEnabled: false, aiBaseUrl: 'https://example.com', aiModel: 'm');

      final restored = UiPrefs.fromJson(original.toJson());

      expect(restored.aiEnabled, isFalse);
      expect(restored.aiBaseUrl, 'https://example.com', reason: '关开关不动已经填好的配置');
      expect(restored.aiModel, 'm');
    });

    test('老偏好文件里没有这个键 → 当作开着，不把功能悄悄关掉', () {
      final restored = UiPrefs.fromJson(<String, dynamic>{'lastTabIndex': 1});
      expect(restored.aiEnabled, isTrue);
    });

    test('copyWith 能单独翻这个开关，且不弄丢其它字段', () {
      const original = UiPrefs(
        lastTabIndex: 2,
        aiBaseUrl: 'https://example.com',
        aiModel: 'm',
      );

      final off = original.copyWith(aiEnabled: false);

      expect(off.aiEnabled, isFalse);
      expect(off.lastTabIndex, 2);
      expect(off.aiBaseUrl, 'https://example.com');
      expect(off.aiModel, 'm');
    });
  });

  test('withExpanded 不会顺手弄丢别的字段', () {
    const original = UiPrefs(
      lastTabIndex: 1,
      compactTaskView: true,
      lastExportedAt: 1788652799999,
      themeId: 'ocean',
      backgroundImagePath: '/p/bg.img',
      backgroundOpacity: 0.5,
      backgroundBlur: 12,
      backgroundSeedHex: '#0e7c86',
    );

    final collapsed = original.withExpanded('node-1', expanded: false);
    expect(collapsed.isExpanded('node-1'), isFalse);
    expect(collapsed.lastTabIndex, 1);
    expect(collapsed.compactTaskView, isTrue);
    expect(collapsed.lastExportedAt, 1788652799999);
    expect(collapsed.themeId, 'ocean');
    expect(collapsed.backgroundImagePath, '/p/bg.img');
    expect(collapsed.backgroundOpacity, 0.5);
    expect(collapsed.backgroundBlur, 12);
    expect(collapsed.backgroundSeedHex, '#0e7c86');

    final expanded = collapsed.withExpanded('node-1', expanded: true);
    expect(expanded.isExpanded('node-1'), isTrue);
    expect(expanded.themeId, 'ocean');
    expect(expanded.backgroundImagePath, '/p/bg.img');
  });

  group('展开 / 收起的两集合语义', () {
    test('没有显式选择时用调用方给的默认值（已完成的任务默认收起）', () {
      const prefs = UiPrefs.empty;
      expect(prefs.isExpanded('t1'), isTrue, reason: '未完成默认展开');
      expect(prefs.isExpanded('t1', defaultExpanded: false), isFalse, reason: '已完成默认收起');
    });

    test('显式展开优先于显式收起', () {
      final prefs = UiPrefs.empty
          .withExpanded('t1', expanded: false)
          .withExpanded('t1', expanded: true);
      expect(prefs.collapsedIds.contains('t1'), isFalse, reason: '两个集合互斥');
      expect(prefs.expandedIds.contains('t1'), isTrue);
      expect(prefs.isExpanded('t1', defaultExpanded: false), isTrue, reason: '手动展开要留得住');
    });

    test('显式收起优先于默认展开', () {
      final prefs = UiPrefs.empty.withExpanded('t1', expanded: false);
      expect(prefs.isExpanded('t1'), isFalse);
      expect(prefs.isExpanded('t1', defaultExpanded: false), isFalse);
    });

    test('两个集合都能 JSON 往返', () {
      final prefs = UiPrefs.empty
          .withExpanded('a', expanded: false)
          .withExpanded('b', expanded: true);
      final restored = UiPrefs.fromJson(prefs.toJson());

      expect(restored.isExpanded('a'), isFalse);
      expect(restored.isExpanded('b'), isTrue);
    });
  });
}
