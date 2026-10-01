import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../features/workspace.dart';
import '../common/dialogs.dart';
import '../common/keyboard_dismiss_guard.dart';
import 'ai_settings_page.dart';

/// AI 整理的结果**写到哪儿**（2026-09-28：同一个功能两个方向）。
enum AiWriteTarget {
  /// 清单 → 正文：写入「如何解决」
  implementation,

  /// 正文 → 清单：**整体替换**实现清单条目
  checklist,
}

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
    this.target = AiWriteTarget.implementation,
  });

  final AppController app;
  final String projectId;
  final String projectTitle;
  final String generated;

  /// 这次的结果往哪儿写（两个方向的预览页是同一页）。
  final AiWriteTarget target;

  @override
  State<AiPreviewPage> createState() => _AiPreviewPageState();
}

class _AiPreviewPageState extends State<AiPreviewPage> {
  late final TextEditingController _text = TextEditingController(text: widget.generated);

  final FocusNode _focus = FocusNode();

  /// 有没有一份可以退回的旧正文（进这一页时先看一眼，写入之后再更新）。
  String? _snapshot;

  /// 已经写入过了 —— 写入后这一页**不再自动关掉**：关掉的话"退回上一版"
  /// 就没有落脚处了（它是本页的动作，项目详情页不参与）。
  bool _applied = false;

  /// 这次拆之前，项目里**已经有的条目文本**（按原顺序）。
  ///
  /// 「拆成条目」是**整体替换**，所以写入之前必须让用户看见"会顶掉这 N 条" ——
  /// 记下来才能在确认框里说清代价，退回时也能把它们按原样放回去。
  List<({String text, bool done})> _beforeItems = const <({String text, bool done})>[];

  @override
  void initState() {
    super.initState();
    _snapshot = widget.app.implementationSnapshot(widget.projectId);
    final project = widget.app.ws.findProject(widget.projectId);
    _beforeItems = <({String text, bool done})>[
      if (project != null)
        for (final item in project.items) (text: item.text, done: item.done),
    ];
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
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
          // **只有"清单 → 正文"那一路用它**：「拆成条目」那一路的退回是
          // 一条带按钮的轻提示（它退的是清单，不是正文）。
          if (_snapshot != null && widget.target == AiWriteTarget.implementation)
            TextButton(
              onPressed: _revert,
              child: const Text('退回上一版'),
            ),
          TextButton(
            // 写入之后按钮就闲着：要改就改上面的文字再点一次也没意义（正文已是这一版），
            // 真想再来一次应该回上一页重新发起整理
            onPressed: _applied ? null : _apply,
            child: Text(_applied ? '已写入' : _applyLabel),
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
              widget.target == AiWriteTarget.checklist
                  ? '可以直接改；一行一条，写入会整体替换现有清单，正文一个字都不动。'
                  : '可以直接改；写入只替换「如何解决」，清单不动。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              // 键盘收起 = **只放掉焦点**（ADR-087）：写入由标题栏那颗按钮决定，
              // 收键盘不是"写入"的意思，草稿一个字都不动。
              child: KeyboardDismissGuard(
                isFocused: () => _focus.hasFocus,
                onKeyboardDismissed: _focus.unfocus,
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
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
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              _footerNote,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 标题栏那个按钮写什么 —— 两个方向落点不同，名字必须跟着走。
  String get _applyLabel {
    if (_applied) return '已写入';
    return widget.target == AiWriteTarget.checklist ? '写入清单' : '写入「如何解决」';
  }

  /// 页脚那句：**只有一句**，但它要回答"写下去会动到什么、能怎么退"。
  String get _footerNote {
    if (widget.target == AiWriteTarget.checklist) {
      final existing = _beforeItems.length;
      if (_applied) {
        return '已写入。写入前的清单已留档，点下方提示里的「退回上一版」可以还原，该留档仅能使用一次。';
      }
      return existing == 0
          ? '这条项目现在没有清单条目，写入就是新建这些条目；正文不动。'
          : '写入会替换现有的 $existing 条清单条目，正文不变；写入后可退回一次。';
    }
    return _applied
        ? '已写入。写入前的正文已留档，点上方「退回上一版」可以还原；'
            '该留档仅能反悔一次，退回后立即失效。'
        : '写入会覆盖原来的「如何解决」，清单条目不动；写入前会自动留一份旧版。';
  }

  void _apply() {
    final text = _text.text.trim();
    if (text.isEmpty) {
      showToast(context, '内容是空的，没什么可写入的', error: true);
      return;
    }
    if (widget.target == AiWriteTarget.checklist) {
      _applyToChecklist();
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

  /// 写入清单：**解析编辑框里的文本**（用户可能已经改过），再整体替换。
  ///
  /// 解析用的是本地那条 `splitImplementationLines`（丢空行、去掉 `-` / `1.` 记号）
  /// —— 模型被要求"一行一条"，但多写记号也不该出错。
  Future<void> _applyToChecklist() async {
    final lines = Workspace.splitImplementationLines(_text.text);
    if (lines.isEmpty) {
      showToast(context, '没解析出任何条目，检查一下格式', error: true);
      return;
    }

    // 整体替换：**会顶掉现有条目**，所以有现存条目时必须先问一句
    if (_beforeItems.isNotEmpty) {
      final ok = await confirmAction(
        context,
        title: '替换现有清单',
        message: '会先清空现有 ${_beforeItems.length} 条，再写入 ${lines.length} 条。本次拆分为一次性结果，原有条目不会自动退回，如需退回只能使用写入后提示里的按钮，该按钮仅能使用一次。',
        confirmLabel: '替换',
        danger: true,
      );
      if (!ok || !mounted) return;
    }

    final error = widget.app.run(
      () => widget.app.ws.replaceProjectItems(widget.projectId, lines),
    );
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    setState(() {
      _applied = true;
      _beforeItems = const <({String text, bool done})>[];
    });
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('已写入 ${lines.length} 条清单条目'),
        action: SnackBarAction(
          label: '退回上一版',
          onPressed: _revertChecklist,
        ),
      ),
    );
  }

  /// 把清单退回成这次拆之前那一批（文本与勾选状态都按原样）。
  void _revertChecklist() {
    final texts = <String>[for (final item in _beforeItems) item.text];
    final error = texts.isEmpty
        ? widget.app.run(() => widget.app.ws.clearProjectItems(widget.projectId))
        : widget.app.run(() => widget.app.ws.replaceProjectItems(widget.projectId, texts));
    if (!mounted) return;
    if (error != null) {
      showToast(context, error, error: true);
      return;
    }
    // 勾选状态单独放回去：`replaceProjectItems` 一律建成未完成
    //
    // ⚠️ **这里刻意不包 `run()`**（2026-10-01 核过，结论是"不用改"）：
    // `setProjectItemDone` 每次都 `persist()`，而 `AppStorage.save` 现在会在
    // "盘上那份属于更新版本的 App" 时抛 `StoreLockedByNewerSchema` ——
    // 光看这一句会以为该包上。但实际**走不到**：
    //   · 被锁住时，上面那次 `replaceProjectItems` 已经被 `run()` 挡下并 `return`；
    //   · 而 `setProjectItemDone` 自己**先校验参数、后碰存储**（项目/条目不存在时
    //     先抛 `RuleViolation`），所以真能进到这个循环时，存储一定是可写的。
    // 也就是说加包装是**不可测的防卫代码** —— 它会让"没人走过的分支"留在库里，
    // 而这正是本项目反复清理的那类东西。真要改就等它变成可达的那一天。
    if (texts.isNotEmpty) {
      final w = widget.app.ws;
      final project = w.findProject(widget.projectId);
      if (project != null) {
        for (var i = 0; i < project.items.length && i < _beforeItems.length; i += 1) {
          if (_beforeItems[i].done) {
            w.setProjectItemDone(widget.projectId, project.items[i].id, true);
          }
        }
      }
    }
    setState(() {
      _applied = false;
      _beforeItems = const <({String text, bool done})>[];
    });
    showToast(context, '已退回上一版清单');
  }

  Future<void> _revert() async {
    final ok = await confirmAction(
      context,
      title: '退回上一版',
      message: '将「如何解决」还原为 AI 覆盖之前的那一版？该留档仅能使用一次，退回后立即失效。',
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

/// 发起 AI 整理：**方向由"手上有什么"自动判**（2026-09-28）。
///
/// ```
/// 清单非空          → 整理成「如何解决」（现有）
/// 清单空、正文非空   → 拆成清单条目（新增；从前这一步是本地的"按行硬拆"）
/// 两边都空          → 不进 AI，提示先写点东西
/// ```
///
/// 为什么不做成两个并列入口：两个方向本来就互斥（一个有清单、一个没清单），
/// 自动判不会歧义，而用户点这一颗按钮的意思是"帮我整理一下"——
/// 该往哪个方向整理是**我们能看出来的**，不该让他先判断再选。
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

  final project = app.ws.findProject(projectId);
  if (project == null || project.deleted) {
    showToast(context, '项目不存在', error: true);
    return;
  }
  // 该往哪个方向走：有清单就先整理成正文；没清单但有正文就拆成条目
  final target = project.items.isNotEmpty
      ? AiWriteTarget.implementation
      : AiWriteTarget.checklist;
  if (target == AiWriteTarget.checklist &&
      project.implementation.trim().isEmpty) {
    showToast(context, '先写点「如何解决」，或者加几条清单条目', error: true);
    return;
  }

  final config = await app.readAiConfig();
  final reason = config.validate();
  if (reason != null && context.mounted) {
    final goSettings = await confirmAction(
      context,
      title: '还没配好 AI',
      message: '$reason。\n\n前往设置填写 API 地址与 Key？Key 存在系统安全存储中，不会进入备份或导出。',
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
  final busyLabel =
      target == AiWriteTarget.checklist ? '正在拆成条目…' : '正在整理…';
  final messenger = showBlockingProgress(context, busyLabel);
  final result = target == AiWriteTarget.checklist
      ? await app.splitProjectItems(projectId)
      : await app.summarizeProjectItems(projectId);
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
        target: target,
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
