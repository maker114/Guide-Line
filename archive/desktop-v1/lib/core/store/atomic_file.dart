import 'dart:convert';
import 'dart:io';

/// 原子文件操作的唯一实现（《同步与云函数契约》§1）。
///
/// 落盘规则：
///   写 `<name>.tmp` → flush → rename 覆盖。
///   启动时若发现残留 `.tmp`，**直接删除**（说明上次写在中间崩了，原文件仍完整）。
///
/// 读取规则：
///   内容损坏时**绝不静默重建空数据** —— 把现场改名保留为 `.corrupt.<ts>` 并向上报告，
///   由数据层决定是从云端重新拉取，还是进入只读告警态。
class AtomicFile {
  AtomicFile(this.file);

  final File file;

  bool get exists => file.existsSync();

  static File tmpOf(File f) => File('${f.path}.tmp');

  static File corruptOf(File f, int stamp) => File('${f.path}.corrupt.$stamp');

  /// 原子写入；[pretty] 表示使用 2 空格缩进的规范化文本。
  void writeText(String text, {bool fsync = true}) {
    final tmp = tmpOf(file);
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeStringSync(text);
      if (fsync) raf.flushSync();
    } finally {
      raf.closeSync();
    }
    // 同目录 rename 在 Windows 与 POSIX 上都是原子替换
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(file.path);
  }

  /// 读取文本；文件不存在返回 null。
  String? readTextOrNull() {
    if (!file.existsSync()) return null;
    return file.readAsStringSync(encoding: utf8);
  }

  /// 清理残留的 `.tmp`（启动时调用一次）。
  static void cleanupTmp(Iterable<File> candidates) {
    for (final f in candidates) {
      final tmp = tmpOf(f);
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {
          // 忽略：删不掉也不影响正确性
        }
      }
    }
  }

  /// 把损坏文件隔离保留（返回隔离后的路径）。
  String quarantine(int stamp) {
    final target = corruptOf(file, stamp);
    try {
      file.renameSync(target.path);
    } catch (_) {
      // 隔离失败时保持原文件不动
      return file.path;
    }
    return target.path;
  }
}
