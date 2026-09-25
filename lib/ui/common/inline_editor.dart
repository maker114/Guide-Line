import 'package:flutter/material.dart';

import '../theme/shape_tokens.dart';

/// 输入框的形状：**单行用胶囊，多行用卡片圆角**（《界面规范》§4）。
///
/// 多行书写区如果也拉成胶囊，会得到两个超大的半圆端，看着更像药丸而不是书写区；
/// 层级规则不变（输入仍是"能点的"），只是按高度换一档更合适的形状。
OutlineInputBorder inputBorderForLines(int maxLines) {
  if (maxLines > 1) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppShapes.cardRadius),
    );
  }
  return const OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppShapes.pillRadius)),
  );
}

/// 页面内直接编辑（**不弹对话框**）。
///
/// 用法是"点一下就变成输入框"：读的时候只显示文字（空值显示浅色提示），
/// 点一下原地变成可编辑，失焦或点键盘的完成即提交。
///
/// 两条刻意的约束：
///   · **值没变就不回调** —— 存储层每次保存都会重写整份文件并轮转备份，
///     不能因为"点了一下又点回去"就白写一次盘；
///   · **必填项被清空时不提交，恢复原值** —— 否则用户一失手就把标题清没了。
class InlineTextField extends StatefulWidget {
  const InlineTextField({
    super.key,
    required this.value,
    required this.onSubmitted,
    this.hint = '点一下输入',
    this.minLines = 1,
    this.maxLines = 1,
    this.allowEmpty = false,
    this.textStyle,
    this.hintStyle,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
    this.autofocus = false,
    this.onEditClosed,
    this.showEditIcon = true,
    this.editorActions = false,
  });

  /// 当前值（外部真源）
  final String value;

  /// 提交回调；只在值真的变了时调用
  final ValueChanged<String> onSubmitted;

  final String hint;
  final int minLines;
  final int maxLines;

  /// 允许提交空值（例如"目的"可以为空）
  final bool allowEmpty;

  final TextStyle? textStyle;
  final TextStyle? hintStyle;
  final EdgeInsets padding;

  /// 一进来就直接进入编辑态（列表里刚点"新建"时用得上）
  final bool autofocus;

  /// 每次**结束编辑**都会调用（无论值有没有变）。
  /// 列表里用来把"正在重命名"的行恢复成普通行。
  final VoidCallback? onEditClosed;

  /// 只读态右侧那个"这里能改"的小铅笔。默认给（多数字段没有别的入口）；
  /// 列表里"点这一行就是改"的地方（清单条目）关掉它 —— 那一行已经点得进去，
  /// 再挂一个图标只是多一个看不出区别的记号（实机反馈）。
  final bool showEditIcon;

  /// 编辑态右侧补上 **确认 / 取消** 两个按钮。
  ///
  /// 原来编辑态只有一个输入框：改完只能靠"点别处"或键盘的完成键提交，
  /// 想放弃改动就只能自己改回去（实机反馈"没有确认和取消键"）。
  final bool editorActions;

  @override
  State<InlineTextField> createState() => _InlineTextFieldState();
}

class _InlineTextFieldState extends State<InlineTextField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startEditing());
    }
  }

  @override
  void didUpdateWidget(InlineTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变了（例如别处改了）而当前不在编辑，就同步过来
    if (!_editing && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus && _editing) _commit();
  }

  void _startEditing() {
    if (!mounted) return;
    setState(() => _editing = true);
    _focus.requestFocus();
  }

  void _commit() {
    final next = _controller.text.trim();
    setState(() => _editing = false);
    if (next == widget.value) {
      widget.onEditClosed?.call();
      return;
    }
    if (next.isEmpty && !widget.allowEmpty) {
      // 必填项被清空：恢复原值，不写盘
      _controller.text = widget.value;
      widget.onEditClosed?.call();
      return;
    }
    widget.onSubmitted(next);
    widget.onEditClosed?.call();
  }

  /// 取消编辑：**丢掉改了一半的内容、恢复原值**，一个字节都不写盘。
  ///
  /// 先把 `_editing` 置回 false 再 `unfocus()`：焦点监听里"失焦即提交"那条
  /// 只认编辑态，顺序反了的话这次取消会被当成一次提交。
  void _cancel() {
    _controller.text = widget.value;
    setState(() => _editing = false);
    _focus.unfocus();
    widget.onEditClosed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_editing) {
      final field = TextField(
        controller: _controller,
        focusNode: _focus,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        textInputAction:
            widget.maxLines > 1 ? TextInputAction.newline : TextInputAction.done,
        style: widget.textStyle,
        decoration: InputDecoration(
          isDense: true,
          border: inputBorderForLines(widget.maxLines),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        onSubmitted: widget.maxLines > 1 ? null : (_) => _commit(),
      );
      return Padding(
        padding: widget.padding,
        child: widget.editorActions
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(child: field),
                  _EditorAction(
                    tooltip: '取消',
                    icon: Icons.close,
                    onPressed: _cancel,
                  ),
                  _EditorAction(
                    tooltip: '确认',
                    icon: Icons.check,
                    onPressed: _commit,
                  ),
                ],
              )
            : field,
      );
    }

    final empty = widget.value.trim().isEmpty;
    return InkWell(
      onTap: _startEditing,
      child: Padding(
        padding: widget.padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(
                empty ? widget.hint : widget.value,
                style: empty
                    ? (widget.hintStyle ??
                        theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline))
                    : widget.textStyle,
              ),
            ),
            // 给一个"这里能改"的轻微提示，不做成显眼按钮
            if (widget.showEditIcon)
              Icon(Icons.edit_outlined, size: 16, color: theme.colorScheme.outlineVariant),
          ],
        ),
      ),
    );
  }
}

/// 行内编辑的 **确认 / 取消** 按钮：比 `IconButton` 小一圈。
///
/// 它们长在一条本来就紧凑的行里（清单条目），默认 48×48 的触摸目标会把行撑高，
/// 所以按 `compact` 密度收成 32×32 —— 仍然够点，也不抢文本的宽度。
class _EditorAction extends StatelessWidget {
  const _EditorAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    );
  }
}

/// 列表里的"直接输入"行：点一下展开成输入框，提交后**保持展开**继续输入，
/// 想收起来点右侧的对勾。像系统「备忘录」那样连着记几条不用反复点。
class InlineComposer extends StatefulWidget {
  const InlineComposer({
    super.key,
    required this.label,
    required this.hint,
    required this.onCreate,
    this.minLines = 1,
    this.maxLines = 1,
    this.leading,
    this.dense = false,
    this.compact = false,
  });

  /// 折叠时显示的文案，例如「新建项目」
  final String label;
  final String hint;
  final ValueChanged<String> onCreate;
  final int minLines;
  final int maxLines;
  final IconData? leading;
  final bool dense;

  /// 折叠时**只显示一个图标按钮**（不显示文字），用于「新建子项目」这类
  /// 想让界面更轻的地方。展开后的输入框完全一样。
  final bool compact;

  @override
  State<InlineComposer> createState() => _InlineComposerState();
}

class _InlineComposerState extends State<InlineComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _expanded = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _expand() {
    setState(() => _expanded = true);
    _focus.requestFocus();
  }

  void _collapse() {
    _controller.clear();
    _focus.unfocus();
    setState(() => _expanded = false);
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onCreate(text);
    // 保持展开，方便接着记下一条
    _controller.clear();
    _focus.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_expanded) {
      if (widget.compact) {
        // 只给一个加号按钮：新建子项目这类入口不必占一整行文字
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: IconButton.filledTonal(
              tooltip: widget.label,
              icon: Icon(widget.leading ?? Icons.add, size: 20),
              onPressed: _expand,
            ),
          ),
        );
      }
      return ListTile(
        dense: widget.dense,
        leading: Icon(widget.leading ?? Icons.add, color: theme.colorScheme.primary),
        title: Text(widget.label, style: TextStyle(color: theme.colorScheme.primary)),
        onTap: _expand,
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              textInputAction:
                  widget.maxLines > 1 ? TextInputAction.newline : TextInputAction.done,
              decoration: InputDecoration(
                hintText: widget.hint,
                isDense: true,
                border: inputBorderForLines(widget.maxLines),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
              onSubmitted: widget.maxLines > 1 ? null : (_) => _submit(),
            ),
          ),
          IconButton(
            tooltip: '添加',
            icon: const Icon(Icons.check),
            onPressed: _submit,
          ),
          IconButton(
            tooltip: '收起',
            icon: const Icon(Icons.close),
            onPressed: _collapse,
          ),
        ],
      ),
    );
  }
}
