import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'platform/data_directory.dart';
import 'ui/app_shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/background_layer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final controller = await AppController.bootstrap();
    runApp(GuidelineApp(controller: controller));
  } catch (error, stack) {
    // 启动阶段（读盘 / 解析）失败时不静默：给出可读错误，并明确"数据没有被改动"
    runApp(_FatalApp(message: '$error', detail: '$stack'));
  }
}

/// GuideLine —— 本地优先的个人生活管理工具（**Android 单机版**）。
///
/// 分层（ADR-024）：
///   `lib/core`     数据层与规则（纯 Dart，**禁止 import Flutter**）
///   `lib/features` 业务逻辑层（Workspace：全部业务规则）
///   `lib/app`      应用装配（控制器与动作门面）
///   `lib/ui`       UI 层（手机外壳 + 各 Tab）
///   `lib/platform` 平台适配层（唯一允许出现平台判断的地方）
///
/// 以上边界由 `test/core/architecture_test.dart` 扫描源码守护。
/// （原双端方案的同步层与云函数已随电脑端成果归档，见 `archive/desktop-v1/`。）
class GuidelineApp extends StatelessWidget {
  const GuidelineApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    // 主题与背景都来自界面偏好，所以整棵树跟着控制器重建
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final prefs = controller.prefs;
        return MaterialApp(
          title: AppInfo.displayName,
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(prefs, Brightness.light),
          darkTheme: buildAppTheme(prefs, Brightness.dark),
          builder: (context, child) => AppBackground(
            bytes: controller.backgroundBytes,
            opacity: prefs.backgroundOpacity,
            blur: prefs.backgroundBlur,
            child: child ?? const SizedBox.shrink(),
          ),
          home: AppShell(app: controller),
        );
      },
    );
  }
}

class _FatalApp extends StatelessWidget {
  const _FatalApp({required this.message, required this.detail});

  final String message;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('启动失败', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              SelectableText(message),
              const SizedBox(height: 8),
              Text(
                '你的数据文件没有被修改 —— 请把上面的信息发给我。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(detail, style: const TextStyle(fontSize: 11)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
