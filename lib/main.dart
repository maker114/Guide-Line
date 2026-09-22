import 'package:flutter/material.dart';

import 'ui/desktop/desktop_shell.dart';

void main() {
  runApp(const GuidelineApp());
}

/// GuideLine 应用入口。
///
/// 分层（设计文档 6.2 / ADR-024）：
///   `lib/core`     数据层与规则（纯 Dart，**禁止 import Flutter**）
///   `lib/sync`     同步层（接口在这里；CloudBase 实现藏在 `sync/cloudbase/` 下）
///   `lib/features` 业务逻辑层
///   `lib/ui`       UI 层（共享组件 + mobile / desktop 两套外壳）
///   `lib/platform` 平台适配层（唯一允许出现平台判断的地方）
///
/// 以上边界由 `test/core/architecture_test.dart` 扫描源码守护。
class GuidelineApp extends StatelessWidget {
  const GuidelineApp({super.key});

  static const String displayName = 'Guide Line';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: displayName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F6FEB),
        useMaterial3: true,
      ),
      home: const DesktopShell(),
    );
  }
}
