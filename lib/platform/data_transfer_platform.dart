import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

/// 平台适配层：**系统分享面板与文件选择器**。
///
/// 这是除数据目录外唯一允许 import 插件的地方（ADR-024）；
/// 业务层只认"给我一个文件路径"和"给我一份字节"，不认 share_plus / file_picker。
class DataTransferPlatform {
  const DataTransferPlatform._();

  /// 把文件交给系统分享面板。
  ///
  /// 返回用户是否真的选了一个目标（取消返回 `false`）——
  /// 导出成功与否不该由"用户有没有分享出去"决定，所以调用方要分开处理。
  static Future<bool> shareFile(
    String path, {
    String? text,
    String? subject,
  }) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(path)],
        text: text,
        subject: subject,
      ),
    );
    return result.status == ShareResultStatus.success;
  }

  /// 让用户挑一个文件；取消返回 `null`。
  ///
  /// 导入数据时**不做扩展名过滤**：Android 上 `.json.gz` 的 MIME 常被识别成
  /// `application/gzip`，按扩展名过滤反而会让用户"看不到自己的文件"；
  /// 内容对不对由解码器判断。选背景图时用 [imagesOnly] 让系统只列图片。
  static Future<PickedTransferFile?> pickFile({
    String? dialogTitle,
    bool imagesOnly = false,
  }) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle ?? '选择文件',
      type: imagesOnly ? FileType.image : FileType.any,
    );
    if (files.isEmpty) return null;
    final file = files.first;
    return PickedTransferFile(name: file.name, bytes: await file.readAsBytes());
  }
}

/// 用户选中的文件（名字 + 全部字节；用字节而不是路径，兼容 content:// 来源）。
class PickedTransferFile {
  const PickedTransferFile({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}
