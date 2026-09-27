import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../common/dialogs.dart';
import 'ai_settings_page.dart';

/// AI 整理的**预览页**（《定义与边界》§10）。
///
/// 这里是整个功能的护栏所在：模型整理完**不直接写库**，先把结果摆在这里让人核对。
/// 之所以必须这样：这是本应用唯一会"生成内容"的地方，而模型**可能补充或改写
/// 清单里没有的东西** —— 直接覆盖正文等于把编造的内容当成自己写的事实。
///
/// 第二道护栏（Q15）：写入前会**自动留一份旧正文**，写完这一页就给一个
/// 「退回上一版」。「原来那段可以先手动备份」是靠不住的 —— 真要反悔的时候，
/// 用户手里没有那段文字。
class AiPreviewPage extends StatefulWidget {
  const AiPreviewPage({
    super.key,
    required this.app,
    required this.projectId,
    required this.projectTitle,
    required this.generated,
  });

  final AppController app;
  final String projectId;
  final String projectTitle;
  final String generated;

  @override
  State<AiPreviewPage> createState() => _AiPreviewPageState();
}

class _AiPreviewPageState extends State<AiPreviewPage> {
  late final TextEditingController _text = TextEditingController(text: widget.generated);

  /// 有没有一份可以退回的旧正文（进这一页时先看一眼，写入之后再更新）。
  String? _snapshot;

  /// 已经写入过了 —— 写入后这一页**不再自动关掉**：关掉的话"退回上一版"
  /// 就没有落脚处了（它是本页的动作，项目详情页不参与）。
  bool _applied = false;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.app.implementationSnapshot(widget.projectId);
  }

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
        title: Text('AI 整理 · ${widget.projectTitle}', overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          // 「退回上一版」放在标题栏而不是页脚：写入成功后那句轻提示正好压在页面底部
          // （实测过：4 秒内点不到页脚的按钮），标题栏这一处永远不会被它挡住。
          if (_snapshot != null)
            TextButton(
              onPressed: _revert,
              child: const Text('退回上一版'),
            ),
          TextButton(
            // 写入之后按钮就闲着：要改就改上面的文字再点一次也没意义（正文已是这一版），
            // 真想再来一次应该回上一页重新发起整理
            onPressed: _applied ? null : _apply,
            child: Text(_applied ? '已写入' : '写入「如何解决」'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 这句是必须的：不能让用户以为这就是自己写的
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.warning_amber_outlined,
                    size: 18, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '模型可能补充或改写你没写过的东西，请逐句核对后再写入。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              '可以直接改；写入只替换「如何解决」，清单不动。',
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
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              _applied
                  ? '已写入。写入前的那一版正文已留档，想反悔就点上面的「退回上一版」——'
                      '留档只值一次反悔，退回后即销掉。'
                  : '写入会覆盖原来的「如何解决」，清单条目不动；写入前会自动留一份旧版。',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  void _apply() {
    final text = _text.text.trim();
    if (text.isEmpty) {
      showToast(context, '内容是空的，没什么可写入的', error: true);
      return;
    }

    // 覆盖之前先留档。只在这句本来就有内容时留：留一份空串等于"退回上一版"把正文清空，
    // 那不是用户想要的（真想清空，自己把编辑框清掉再写入即可）。
    final before = widget.app.currentImplementation(widget.projectId);
    if (before.trim().isNotEmpty) {
      widget.app.saveImplementationSnapshot(widget.projectId, before);
    }

    final error = widget.app.run(
      () => widget.app.ws.replaceImplementation(widget.projectId, text),
    );
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    // 不自动 pop：留着这一页，"退回上一版"才有落脚处（用户自己按返回离开）
    setState(() {
      _applied = true;
      _snapshot = widget.app.implementationSnapshot(widget.projectId);
    });
    showToast(context, '已写入「如何解决」');
  }

  Future<void> _revert() async {
    final ok = await confirmAction(
      context,
      title: '退回上一版',
      message: '把「如何解决」换回 AI 覆盖之前那一版？\n'
          '这份留档只会用这一次，退回之后就销掉了。',
      confirmLabel: '退回',
    );
    if (!ok || !mounted) return;

    final error = widget.app.revertImplementation(widget.projectId);
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    setState(() {
      _applied = false;
      _snapshot = null;
      // 编辑框回到刚退回的那一版：否则屏幕上写着一版、库里是另一版，
      // 再点一次「写入实现计划」又把它推回去了
      _text.text = widget.app.currentImplementation(widget.projectId);
    });
    showToast(context, '已退回上一版「如何解决」');
  }
}

/// 发起整理：先取配置，未配置就引导去设置；成功则进预览页。
Future<void> startAiSummarize(
  BuildContext context,
  AppController app,
  String projectId,
  String projectTitle,
) async {
  // 总开关关着时不该走到这里（入口已经藏了），但别把"点了没反应"留成可能：
  // 真被调到就明说去哪儿打开。
  if (!app.aiEnabled) {
    showToast(context, 'AI 整理已关闭，去「更多 → AI 整理」里打开', error: true);
    return;
  }

  final config = await app.readAiConfig();
  final reason = config.validate();
  if (reason != null && context.mounted) {
    final goSettings = await confirmAction(
      context,
      title: '还没配好 AI',
      message: '$reason。\n\n去设置里填 API 地址与 Key 吗？Key 存在系统安全存储里，不会进备份或导出',
      confirmLabel: '去设置',
    );
    if (goSettings && context.mounted) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => AiSettingsPage(app: app)),
      );
    }
    return;
  }

  if (!context.mounted) return;
  final messenger = showBlockingProgress(context, '正在整理…');
  final result = await app.summarizeProjectItems(projectId);
  messenger.close();

  if (!context.mounted) return;
  if (result.error != null) {
    showToast(context, result.error!, error: true);
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AiPreviewPage(
        app: app,
        projectId: projectId,
        projectTitle: projectTitle,
        generated: result.text ?? '',
      ),
    ),
  );
}

/// 一个最简单的"正在处理"提示，返回一个 close() 用来关掉它。
///
/// 不引第三方弹窗库：这里只需要"挡住界面 + 一句文案"，
/// 用 `showDialog` + 空的 `PopScope` 就够。
({void Function() close}) showBlockingProgress(BuildContext context, String message) {
  var closed = false;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: <Widget>[
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 14),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
  return (
    close: () {
      if (closed) return;
      closed = true;
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    },
  );
}
