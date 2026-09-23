import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'platform/data_directory.dart';
import 'ui/desktop/desktop_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(GuidelineApp(controller: AppController.bootstrap()));
  } catch (error, stack) {
    // 启动阶段（读盘 / 解析）失败时不静默：给出可读错误，并明确"数据没有被改动"
    runApp(_FatalApp(message: '$error', detail: '$stack'));
  }
}

/// GuideLine 应用入口。
///
/// 分层（设计文档 6.2 / ADR-024）：
///   `lib/core`     数据层与规则（纯 Dart，**禁止 import Flutter**）
///   `lib/sync`     同步层（接口 + 引擎；具体后端实现也放这里）
///   `lib/features` 业务逻辑层（Workspace：全部业务规则）
///   `lib/app`      应用装配（控制器与动作门面）
///   `lib/ui`       UI 层（共享组件 + desktop 外壳）
///   `lib/platform` 平台适配层（唯一允许出现平台判断的地方）
///
/// 以上边界由 `test/core/architecture_test.dart` 扫描源码守护。
class GuidelineApp extends StatelessWidget {
  const GuidelineApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.displayName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F6FEB),
        useMaterial3: true,
      ),
      home: DesktopShell(app: controller),
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
          padding: const EdgeInsets.all(32),
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
