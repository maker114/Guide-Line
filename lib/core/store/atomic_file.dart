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

  /// **真正的落盘钩子**（P1-4）。
  ///
  /// `RandomAccessFile.flushSync()` 只把用户态缓冲交给内核，**不等价于 POSIX `fsync`** ——
  /// 而 Dart 标准库没有暴露 `fsync`。所以这里留一个注入点：平台层（`lib/platform/`）
  /// 在启动时把它接到 Android 的 `Os.fsync(fd)` 上，core 保持纯 Dart（默认 no-op）。
  ///
  /// 不设它也不会错，只是回到"以为落盘了、其实还在 page cache 里"的老状态 ——
  /// 手机最主流的非正常退出恰好是掉电，那时最坏会拿到一个 0 字节或半截的主文件。
  static void Function(String path)? fsyncHook;

  /// 尽力把某个文件刷到存储介质上；没有钩子或失败都**不阻断写入流程**。
  static void _durableFlush(String path) {
    final hook = fsyncHook;
    if (hook == null) return;
    try {
      hook(path);
    } catch (_) {
      // 落盘加固失败不该让一次正常保存变成失败：内容已经写进内核缓冲，
      // 只是在"掉电"这个边界上退回到原来的可靠性
    }
  }

  /// 测试用的失败注入点：**换掉"改名"这一步**（默认 `null` = 真的改名）。
  ///
  /// 为什么需要它：守 `_replace` / `_replaceViaOld` 兜底的用例（P1-1）原先靠
  /// Windows 的 `attrib +R` 制造失败，而 `attrib` 是 Windows 专用命令 ——
  /// Ubuntu CI 上 `Process.runSync` 直接抛 `ProcessException`，
  /// **CI 从 2026-09-27 建立起就一直红在这两条用例上**。
  /// 换成注入点之后，两个平台走的是**同一条**确定性路径，也不再依赖操作系统的
  /// 权限语义（`chmod` 目录只读只会在创建 `.tmp` 时就抛，根本走不到要守的兜底；
  /// Windows 上给目录加只读属性又拦不住新建文件）。
  ///
  /// 生产代码永不设置它。
  static void Function(File from, File to)? renameHook;

  /// 测试用的失败注入点：**换掉"复制"这一步**（默认 `null` = 真的复制）。
  ///
  /// 与 [renameHook] 分开是必要的：备份轮转里"移位"走改名、"留下最新那份"走复制
  /// （见 `AppStorage._rotateBackups`），而**权限 / 磁盘满最常见的表现是复制失败**
  /// （`copySync` 要真写一份新文件）。只拦改名的话，备份那一步会照样成功，
  /// 于是"备份没写出来"这条路径根本测不到 —— 2026-10-01 就是这样漏掉了一个
  /// "没写出来却报成功"的缺陷（`snapshotBackupNow`）。
  ///
  /// 生产代码永不设置它。
  static void Function(File from, File to)? copyHook;

  static void _rename(File from, File to) {
    final hook = renameHook;
    if (hook != null) {
      hook(from, to);
      return;
    }
    from.renameSync(to.path);
  }

  /// 复制一个文件（备份留档用）。
  ///
  /// 走 [copyHook] 时由钩子决定成败；否则 `copySync`。**抛出的异常由调用方处理** ——
  /// 备份失败不该阻断主流程，那是 `AppStorage._copyFile` 的职责。
  static void copyFile(File from, File to) {
    final hook = copyHook;
    if (hook != null) {
      hook(from, to);
      return;
    }
    from.copySync(to.path);
  }

  static File tmpOf(File f) => File('${f.path}.tmp');

  static File corruptOf(File f, int stamp) => File('${f.path}.corrupt.$stamp');

  /// 原子写入文本（UTF-8）；[fsync] 为真时落盘前调用 flush，并在 rename 之后再走一次
  /// [fsyncHook]（真正的 fsync，见上）。
  void writeText(String text, {bool fsync = true}) {
    final tmp = tmpOf(file);
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeStringSync(text);
      if (fsync) raf.flushSync();
    } finally {
      raf.closeSync();
    }
    if (fsync) _durableFlush(tmp.path);
    _replace(tmp);
    if (fsync) _durableFlush(file.path);
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
    if (fsync) _durableFlush(tmp.path);
    _replace(tmp);
    if (fsync) _durableFlush(file.path);
  }

  /// 同目录 rename = 原子替换。这是单文件存储「全有或全无」的根基。
  ///
  /// POSIX（Android / Linux / macOS）上 `rename(2)` 会**直接覆盖**已存在的目标，一步到位；
  /// Dart 的 `File.renameSync` 在 Windows 上也走覆盖式移动，所以第一条路几乎总能成功。
  ///
  /// 失败时**不再用「先删目标再改名」**：`renameSync` 还会因为权限被拒（EACCES / EPERM）、
  /// 磁盘配额（EDQUOT）、文件被占用（EBUSY）、路径过长（ENAMETOOLONG）而抛，
  /// 而旧写法无条件删掉目标再试一次 —— 一旦第二次同样失败，**唯一的主文件就没了**，
  /// 留下的 `.tmp` 又会在下次启动被 `cleanupTmp` 当垃圾清掉，两个副本同时消失。
  ///
  /// 现在的兜底只在"目标确实存在"时动手，而且用 `.old` 中转：
  /// 任何一步失败，盘上都至少留着一份完整的数据（要么原文件，要么 `.old`）。
  void _replace(File tmp) {
    try {
      _rename(tmp, file);
      return;
    } catch (error) {
      if (file.existsSync()) {
        _replaceViaOld(tmp, error);
        return;
      }
      // 目标都不存在还失败，说明不是"不允许覆盖"（多半是权限 / 配额）——
      // 这种错误删掉什么都不会变好，直接往上报。
      rethrow;
    }
  }

  /// 覆盖式 rename 不被允许时的兜底（现在的实现只在极少数文件系统上会走到）。
  ///
  /// 安全三步：目标 → `.old` → 临时文件 → 目标 → 删 `.old`。
  /// 任何一步失败，盘上都至少留着一份完整的数据（要么原文件，要么 `.old`）。
  void _replaceViaOld(File tmp, Object originalError) {
    final old = File('${file.path}.old');
    if (old.existsSync()) {
      try {
        old.deleteSync();
      } catch (_) {
        // 删不掉就直接改上去，rename 一样会覆盖它
      }
    }
    try {
      _rename(file, old);
    } catch (_) {
      // 连中转都做不到：原文件还在原位，什么都没坏
      throw originalError;
    }
    try {
      _rename(tmp, file);
    } catch (_) {
      // 新文件没就位：把原文件改回来，绝不让"目标位空着"
      try {
        _rename(old, file);
      } catch (_) {
        // 连回改都失败：`.old` 仍在盘上，数据没丢，留给人工处理
      }
      throw originalError;
    }
    try {
      old.deleteSync();
    } catch (_) {
      // 清理残留不影响正确性
    }
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

  /// 清掉**整个目录里**残留的 `.tmp`（含子目录，启动时调用一次）。
  ///
  /// 为什么需要它、而 [cleanupTmp] 不够（2026-10-01 补，独立核验指出）：
  /// [cleanupTmp] 要调用方**先列出文件**，于是"哪些文件会原子写"这件事散在各处；
  /// 而导出与交接说明写在 `exports/` **子目录**里（`writeExport` /
  /// `writeHandoffExport`），它们的 `.tmp` 谁也没列到、一直没人清。
  ///
  /// 这个方法的判据**不是"这是哪个文件"，而是"这个名字是不是临时文件"** ——
  /// [AtomicFile] 写盘时临时文件恒定叫 `<目标名>.tmp`，所以按名字扫就把
  /// "所有原子写的落点"一次覆盖，**新增写入点不必回来登记**。
  /// 这也顺带修掉了 [AppPaths.atomicWrittenFiles] 那种"列清单"思路的根因：
  /// 清单会漏，扫目录不会。
  ///
  /// 递归（`followLinks: false`）：`exports/` 是一层，但不再赌它永远只有一层。
  static int cleanupTmpIn(Directory dir) {
    if (!dir.existsSync()) return 0;
    var removed = 0;
    try {
      for (final entry in dir.listSync(recursive: true, followLinks: false)) {
        if (entry is! File) continue;
        if (!entry.path.endsWith('.tmp')) continue;
        try {
          entry.deleteSync();
          removed += 1;
        } catch (_) {
          // 忽略：删不掉也不影响正确性
        }
      }
    } catch (_) {
      // 目录读不了也不该阻断启动
    }
    return removed;
  }

  /// 把损坏文件隔离保留（返回隔离后的路径）。
  ///
  /// **不覆盖已有的现场**：同一毫秒里连续隔离两次（同一测试里就会发生）、
  /// 或时钟被回拨，原来的实现会让第二份把第一份静默盖掉 —— 而那两份现场
  /// 恰恰是"最后一道人工求救通道"。目标已存在时依次取 `-2` / `-3` …
  ///
  /// **失败时返回 `null`，不再返回主文件自己的路径**（2026-10-01 修）。
  /// 旧写法失败时 `return file.path`，而调用方（`AppStorage.load`）把返回值
  /// 无条件记进 `quarantinedPaths` —— 于是：
  ///   · 界面上那条"已隔离保留现场"的告警**指向主文件本身**，那不是现场；
  ///   · 紧接着 `_writeBackRecovered` 写的**正是同一路径**，
  ///     等于告警指着的文件下一刻就被覆盖了。
  /// 调用方现在必须先看是不是 `null`，再决定说什么。
  String? quarantine(int stamp) {
    var target = corruptOf(file, stamp);
    var attempt = 1;
    while (target.existsSync()) {
      attempt += 1;
      target = File('${corruptOf(file, stamp).path}-$attempt');
    }
    try {
      file.renameSync(target.path);
    } catch (_) {
      // 隔离失败时保持原文件不动
      return null;
    }
    return target.path;
  }

  /// 隔离区的文件（按名字倒序 = 新的在前）。
  static List<File> quarantineFilesIn(Directory dir) {
    if (!dir.existsSync()) return <File>[];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.contains('.corrupt.'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
