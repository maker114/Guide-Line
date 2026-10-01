import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/app_controller.dart';
import 'platform/data_directory.dart';
import 'platform/file_durability_platform.dart';
import 'ui/app_shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/background_layer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // **在任何写盘之前**把落盘钩子接上（P1-4）：core 保持纯 Dart，
  // 真正的 `fsync` 由平台层走方法通道完成。非 Android 平台静默跳过。
  FileDurabilityPlatform.bind();
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
/// （原双端方案的同步层与云函数已随电脑端成果一起搁置，那份代码只留在 git 历史里。）
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
          // 编辑会话的观察者（Q3）：推开一个页面就是"一段编辑会话"，回到外壳就结束。
          // 注册在这里而不是逐页埋点，是因为编辑面散在好几处、分属不同批次，
          // 逐页加 begin/end 必然会漏；"进页面 → 离开"对所有页面都是同一个形状。
          navigatorObservers: <NavigatorObserver>[controller.editSessionObserver],
          theme: buildAppTheme(prefs, Brightness.light),
          darkTheme: buildAppTheme(prefs, Brightness.dark),
          // 深色 / 亮色怎么取**由偏好决定**（默认跟随系统）。
          //
          // 从前这里没给 `themeMode`，`MaterialApp` 的默认值就是 `system` ——
          // 于是"跟随系统"一直是**唯一**的行为，想固定用深色也没有入口。
          // 现在三个取值都能在「更多 → 主题与背景」里选（`ui_prefs.themeMode`）。
          themeMode: themeModeOf(prefs),
          // 中文本地化（2026-10-02 加）：应用自己的文案一直是中文，但 **Flutter
          // 内置组件**的文案默认只有英文 —— 关于弹窗上那两颗 "View licenses" /
          // "Close" 就是这么来的，也是全应用唯一没本地化的地方。
          //
          // 只声明 `zh` 一种：这不是"支持多语言"，而是**把内置文案钉到中文**。
          // 列的候选只有中文，系统语言是别的也仍走中文，与"应用只有中文文案"
          // 这个既有事实一致（声明十几种反而会让内置文案跟着系统语言变，
          // 于是界面一半中文一半英文）。
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const <Locale>[Locale('zh')],
          locale: const Locale('zh'),
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
                '你的数据文件没有被修改，请把上面的信息发送给我。',
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
