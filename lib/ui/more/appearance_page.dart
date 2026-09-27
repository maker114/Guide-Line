import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../platform/data_transfer_platform.dart';
import '../common/dialogs.dart';
import '../common/section_header.dart';
import '../theme/app_theme.dart';
import '../theme/palette.dart';
import '../theme/shape_tokens.dart';

/// 外观：主题配色 + 背景图（背景图是**实验性**的）。
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key, required this.app});

  final AppController app;

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  bool _busy = false;

  AppController get _app => widget.app;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _app,
      builder: (context, _) {
        final theme = Theme.of(context);
        final prefs = _app.prefs;
        final followSeed = parseHexColor(prefs.backgroundSeedHex);

        return Scaffold(
          appBar: AppBar(title: const Text('外观')),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: <Widget>[
              const SectionHeader('主题'),
              for (final preset in appThemePresets)
                ListTile(
                  leading: _Swatch(color: preset.seed),
                  title: Text(preset.name),
                  subtitle: Text(preset.mood, style: theme.textTheme.labelSmall),
                  trailing: prefs.themeId == preset.id ? const Icon(Icons.check) : null,
                  onTap: () => _app.updatePrefs(prefs.copyWith(themeId: preset.id)),
                ),
              ListTile(
                enabled: prefs.hasBackground && followSeed != null,
                leading: _Swatch(
                  color: followSeed ?? theme.colorScheme.outlineVariant,
                ),
                title: const Text('跟随背景图'),
                subtitle: Text(
                  prefs.hasBackground
                      ? (followSeed == null ? '没能从这张图里取到颜色' : '用背景图的主色生成整套配色')
                      : '先选一张背景图',
                  style: theme.textTheme.labelSmall,
                ),
                trailing: prefs.themeId == followBackgroundThemeId
                    ? const Icon(Icons.check)
                    : null,
                onTap: (prefs.hasBackground && followSeed != null)
                    ? () => _app.updatePrefs(
                          prefs.copyWith(themeId: followBackgroundThemeId),
                        )
                    : null,
              ),

              const SectionHeader('背景图 · 实验性'),
              if (_app.backgroundBytes != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppShapes.nestedRadius),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Image.memory(
                        _app.backgroundBytes!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Center(child: Text('这张图读不出来了')),
                        ),
                      ),
                    ),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add_photo_alternate_outlined),
                title: Text(prefs.hasBackground ? '换一张背景图' : '选择背景图'),
                subtitle: const Text('图会拷进应用私有目录'),
                enabled: !_busy,
                onTap: _busy ? null : () => _pickBackground(context),
              ),
              if (prefs.hasBackground) ...<Widget>[
                ListTile(
                  leading: const Icon(Icons.hide_image_outlined),
                  title: const Text('移除背景图'),
                  enabled: !_busy,
                  onTap: _busy
                      ? null
                      : () {
                          _app.clearBackgroundImage();
                          showToast(context, '已移除背景图');
                        },
                ),
                _SliderTile(
                  icon: Icons.opacity,
                  title: '背景强度',
                  value: prefs.backgroundOpacity,
                  min: minBackgroundOpacity,
                  max: maxBackgroundOpacity,
                  label: '${(prefs.backgroundOpacity * 100).round()}%',
                  onChanged: (value) =>
                      _app.updatePrefs(prefs.copyWith(backgroundOpacity: value)),
                ),
                _SliderTile(
                  icon: Icons.blur_on,
                  title: '模糊',
                  value: prefs.backgroundBlur,
                  min: 0,
                  max: 24,
                  label: '${prefs.backgroundBlur.round()}',
                  onChanged: (value) =>
                      _app.updatePrefs(prefs.copyWith(backgroundBlur: value)),
                ),
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickBackground(BuildContext context) async {
    // 函数自身也要认 `_busy`（Q-7）：`onTap` 上那个判断只关掉了按钮，
    // 挡不住无障碍焦点 / 热键再进来一次。
    if (_busy) return;
    setState(() => _busy = true);
    try {
      PickedTransferFile? picked;
      String? seedHex;
      try {
        picked = await DataTransferPlatform.pickFile(
          dialogTitle: '选择一张背景图',
          imagesOnly: true,
        );
        if (picked != null) {
          // 取主色是"跟随背景图"主题要用的；取不到也不影响设背景
          final seed = await seedColorFromImageBytes(Uint8List.fromList(picked.bytes));
          if (seed != null) seedHex = toHexColor(seed);
        }
      } catch (error) {
        if (mounted && context.mounted) {
          showToast(context, '选择失败：$error', error: true);
        }
        return;
      }
      if (!mounted || picked == null || !context.mounted) return;

      final error = _app.applyBackgroundImage(picked.bytes, seedHex: seedHex);
      if (!context.mounted) return;
      if (error != null) {
        showToast(context, error, error: true);
        return;
      }
      showToast(
        context,
        seedHex == null ? '已设置背景图，没能取到主色' : '已设置背景图，主色 $seedHex',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Text(title),
              const Spacer(),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
