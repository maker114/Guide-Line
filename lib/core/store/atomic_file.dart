import 'dart:convert';
import 'dart:io';

/// 原子文件操作的唯一实现。
///
/// 落盘规则：
///   写 `<name>.tmp` → flush → rename 覆盖。
///   启动时若发现残留 `.tmp`，**直接删除**（说明上次写在中间崩了，原文件仍完整）。
///
/// 读取规则：
///   内容损坏时**绝不静默重建空数据** —— 把现场改名保留为 `.corrupt.<ts>` 并向上报告，
///   由数据层决定是从备份恢复，还是进入只读告警态。
class AtomicFile {
  AtomicFile(this.file);

  final File file;

  bool get exists => file.existsSync();

  static File tmpOf(File f) => File('${f.path}.tmp');

  static File corruptOf(File f, int stamp) => File('${f.path}.corrupt.$stamp');

  /// 原子写入文本（UTF-8）；[fsync] 为真时落盘前调用 flush。
  void writeText(String text, {bool fsync = true}) {
    final tmp = tmpOf(file);
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeStringSync(text);
      if (fsync) raf.flushSync();
    } finally {
      raf.closeSync();
    }
    _replace(tmp);
  }

  /// 原子写入字节（备份轮转时直接复制内容，避免"读成字符串再写回"的编码风险）。
  void writeBytes(List<int> bytes, {bool fsync = true}) {
    final tmp = tmpOf(file);
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeFromSync(bytes);
      if (fsync) raf.flushSync();
    } finally {
      raf.closeSync();
    }
    _replace(tmp);
  }

  /// 同目录 rename = 原子替换。这是单文件存储「全有或全无」的根基。
  ///
  /// POSIX（Android / Linux / macOS）上 `rename(2)` 会**直接覆盖**已存在的目标，一步到位；
  /// 所以先试 rename。只有平台不允许覆盖时（某些文件系统 / Windows 的旧行为）才退化成
  /// 「先删后改名」——那两步之间有一个窗口，此刻进程被杀就会**丢失主文件**，
  /// 因此绝不能把它当首选路径。
  void _replace(File tmp) {
    try {
      tmp.renameSync(file.path);
      return;
    } catch (_) {
      // 落到这里说明目标存在且平台不允许 rename 覆盖，退回两步法
    }
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
