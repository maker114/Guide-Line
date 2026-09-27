import 'dart:io';

import 'package:flutter/services.dart';

import '../core/store/atomic_file.dart';

/// 平台适配层：**把真正落盘这件事交给原生**（P1-4）。
///
/// 为什么需要它：`RandomAccessFile.flushSync()` 只是把用户态缓冲交给内核，
/// **不等价于 POSIX `fsync`**，而 Dart 标准库没有暴露 `fsync`。手机最主流的
/// 非正常退出恰好是掉电关机 —— 那一刻数据可能还在 page cache 里，
/// rename 的目录项也可能没落盘，最坏结果是拿到一个 0 字节或半截的主文件。
///
/// 这里用一条 MethodChannel 把路径交给 Kotlin 侧，由它对文件描述符调 `Os.fsync`。
/// 通道不存在时（桌面调试 / 单元测试 / 其它平台）**静默降级为不加固**，
/// 绝不抛错、也绝不阻断保存流程。
class FileDurabilityPlatform {
  const FileDurabilityPlatform._();

  static const MethodChannel _channel = MethodChannel('guideline/file_durability');

  /// 把 [AtomicFile.fsyncHook] 接到原生实现上。在 `main` 里调一次。
  ///
  /// **只在 Android 上接**：其它平台（含单元测试的 Linux 宿主）没有这条通道，
  /// 接了也只是每次写盘多一次失败的跨平台调用。桌面兜底的数据目录本身就是开发用。
  static void bind() {
    if (!Platform.isAndroid) return;
    AtomicFile.fsyncHook = _fsync;
  }

  static void _fsync(String path) {
    // 故意不 await：`AtomicFile` 的写入路径是同步的，而这里只需要"尽力刷"。
    // 失败（通道缺失 / 系统调用被拒）都会被吞掉 —— 见类文档的降级说明。
    _channel.invokeMethod<void>('fsync', <String, Object?>{'path': path}).catchError(
      (Object _) {
        // 降级：不加固，但保存照常成功
      },
    );
  }
}
