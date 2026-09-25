import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../common/dialogs.dart';

/// 交接说明的**预览页**（设计文档 §3.1）。
///
/// 生成好的 Markdown 先在这里全文显示，**可编辑** —— 用户能删掉不想给出去的部分。
/// 预览页本身就是确认环节，所以导出前不再另弹确认框；
/// 但底部**固定**一句话提醒"文件会离开这台手机"。
class HandoffPreviewPage extends StatefulWidget {
  const HandoffPreviewPage({
    super.key,
    required this.app,
    required this.projectId,
    required this.projectTitle,
    required this.markdown,
  });

  final AppController app;
  final String projectId;
  final String projectTitle;
  final String markdown;

  @override
  State<HandoffPreviewPage> createState() => _HandoffPreviewPageState();
}

class _HandoffPreviewPageState extends State<HandoffPreviewPage> {
  late final TextEditingController _text = TextEditingController(text: widget.markdown);
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('交接说明 · ${widget.projectTitle}', overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          TextButton(
            onPressed: _busy ? null : _export,
            child: Text(_busy ? '导出中…' : '导出为 .md'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text(
              '下面这份就是将要导出的内容，可以直接改 —— 不想给出去的部分删掉即可。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _text,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: <Widget>[
                Icon(Icons.info_outline, size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '导出后文件会离开这台手机；请确认上面没有你不想外发的内容。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      showToast(context, '内容是空的，没什么可导出的', error: true);
      return;
    }
    setState(() => _busy = true);
    final result = await widget.app.exportHandoffAndShare(
      projectId: widget.projectId,
      markdown: '${_text.text.trimRight()}\n',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context, result.message, error: !result.ok);
  }
}
