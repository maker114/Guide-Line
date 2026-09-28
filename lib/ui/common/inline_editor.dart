import 'package:flutter/material.dart';

import '../theme/shape_tokens.dart';
import 'animated_collapse.dart';
import 'keyboard_dismiss_guard.dart';

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
    this.editorActions = true,
    this.decorated = false,
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

  /// 编辑态右侧补上 **确认 / 取消** 两个按钮。**默认给**（Q33）。
  ///
  /// 这个开关原来默认是关的，全仓只有清单条目那一处显式打开 ——
  /// 于是项目重命名、灵感改内容、事件名、如何解决都只剩"点别处"和键盘完成键
  /// 两条提交路径，想放弃改动还得自己改回去（实机反馈"没有确认和取消键"）。
  /// 改成默认打开，一处生效；确实不该有的地方再显式关掉并写明理由。
  final bool editorActions;

  /// 只读态画一层**底色框**（`surfaceContainerHighest` 淡底 + 卡片圆角）。
  ///
  /// 默认关：多数字段就长在一行里，加框会平白多一圈。开着的是「实现 · 文本」——
  /// 正文是一整段自由高度的内容，需要与清单侧的勾选骨架对称的"自己的容器"
  /// （2026-09-28 实机反馈：正文那一侧看着像"一半有设计一半没有"）。
  final bool decorated;

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
      // 闭包持有 State，帧回调可能在销毁之后才跑到 —— 与项目其它地方同一个规矩（Q-10）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startEditing();
      });
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
    // **编辑中被移出树也要收掉父级的"正在编辑"状态**（实机反馈：收起 / 展开
    // 分类时输入框会自己弹出来）。
    //
    // 父级是靠 `onEditClosed` 才把"正在改哪一行"清掉的，而这条回调原来只挂在
    // `_commit` / `_cancel` 上 —— 于是"编辑中的那一行被折叠收走"会让父级的
    // 改名 id 一直非空；那一行再出现时（`autofocus: true`）就自己重新进入编辑态，
    // 表现为"我只是收了个下级，输入框和键盘自己跳出来"。
    //
    // 这里只传当前值、**不写盘**：被移出树的编辑会话等于放弃改动，
    // 与 `_cancel` 同一条口径；提交仍然只走用户显式点确认 / 键盘完成那条路。
    final onClosed = widget.onEditClosed;
    if (onClosed != null && _editing) {
      // 不能在 dispose 里同步 setState（父级可能正在 rebuild），推到下一帧
      WidgetsBinding.instance.addPostFrameCallback((_) => onClosed());
    }
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus && _editing) _commit();
  }

  void _startEditing() {
    if (!mounted) return;
    setState(() => _editing = true);
    _focus.requestFocus();
    _scrollIntoView();
  }

  /// 把这一行滚到键盘之上。
  ///
  /// 实机反馈："在修改靠近屏幕下方的灵感的时候，弹出的键盘会挡住输入框"。
  ///
  /// 为什么必须自己滚：`AppShell` 用的是 `resizeToAvoidBottomInset: false`
  /// （键盘只覆盖、不压缩布局，否则底栏与内容之间会裂开一条键盘高的空档），
  /// 所以**系统不会替我们把光标挪进可见区** —— 靠 `ListView` 的自动滚动也只在
  /// `EditableText` 自己触发的场景下生效，而这里的编辑态是**整块换widget**，
  /// 那一套不接管。于是焦点一到手就主动滚一次。
  ///
  /// 推一帧再滚：`_editing = true` 之后编辑框才被建出来，同一帧里还没有它的位置。
  void _scrollIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final target = box.localToGlobal(Offset.zero) & box.size;
      // 键盘高度只能从 `viewInsets` 拿（布局没被压缩，得自己算可用区）
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      final screen = MediaQuery.sizeOf(context).height;
      final visibleBottom = screen - keyboard;
      // 已经整个露在键盘之上就不用动
      if (target.bottom <= visibleBottom - 8) return;
      Scrollable.ensureVisible(
        context,
        alignment: 1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _commit() {
    final next = _controller.text.trim();
    setState(() => _editing = false);
    // **提交之后必须自己放掉焦点**（2026-09-28 实机反馈："点确认之后输入框不会消失，
    // 手动关掉键盘后每次切回该界面就会弹出键盘"）。
    //
    // 崩溃点在于：`_editing = false` 只是把编辑框从树上换成只读文字，而 `FocusNode`
    // 是 State 的字段、**不会因为控件被换掉就释放** —— 于是 primaryFocus 一直挂在
    // 这个已经不在屏幕上的输入框上：键盘不收，页面被 KeepAlive 保活之后再切回来
    // 又是一副"正在编辑"的样子。实测 `primaryFocus.hasFocus == true`。
    //
    // 顺序要紧：先落 `_editing` 再 unfocus —— 焦点监听里"失焦即提交"那条只认编辑态，
    // 反了会再走一次 `_commit`（与 `_cancel` 同一个坑）。
    _focus.unfocus();
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
    final Widget body = _editing
        ? _buildEditor(theme)
        : _buildReadOnly(theme);
    return KeyboardDismissGuard(
      // 焦点还在自己身上、"编辑态"也还在 → 是收键盘，不是换输入框
      isFocused: () => _focus.hasFocus && _editing,
      // **键盘一收起就收掉这次编辑会话**（2026-09-28 实机反馈）：按"确认"处理，
      // 与点键盘上那个完成键一模一样 —— 用户敲完一句、按返回键收键盘，
      // 意思通常是"我写完了"，再让他点一次「确认」是多余的。
      // 代价：收键盘等于保存，想放弃改动只能点「取消」。
      onKeyboardDismissed: _commit,
      child: AnimatedSize(
        duration: expandCollapseDuration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: expandCollapseDuration,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: KeyedSubtree(
            key: ValueKey<bool>(_editing),
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    {
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
  }

  Widget _buildReadOnly(ThemeData theme) {
    final empty = widget.value.trim().isEmpty;
    final box = BoxDecoration(
      // 只给底色与圆角，**不描边**：这一页的卡片已经有一圈圆角了，
      // 再描一圈就成"框里套框"（与「有什么问题 / 思路」那种字段观感不一致）
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(AppShapes.cardRadius),
    );
    return InkWell(
      onTap: _startEditing,
      borderRadius: widget.decorated ? BorderRadius.circular(AppShapes.cardRadius) : null,
      child: Container(
        // 有框时：底色 + 圆角由这一层给，内边距固定 12/10；
        // 没框时（默认）：内边距走调用方给的 `widget.padding`，一个像素都不多画
        decoration: widget.decorated ? box : null,
        padding: widget.decorated
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
            : widget.padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(
                empty ? widget.hint : widget.value,
                style: empty
                    ? (widget.hintStyle ??
                        theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline))
                    : widget.textStyle,
              ),
            ),
            // 给一个"这里能改"的轻微提示，不做成显眼按钮
            if (widget.showEditIcon)
              Icon(Icons.edit_outlined,
                  size: 16, color: theme.colorScheme.outlineVariant),
          ],
        ),
      ),
    );
  }
}

/// 行内编辑的 **确认 / 取消** 按钮：比 `IconButton` 小一圈。
///
/// 它们长在一条本来就紧凑的行里（清单条目、项目名、事件名……），默认 48×48
/// 的触摸目标会把行撑高、还会把文本宽度挤没，所以按 `compact` 密度收成 32×32 ——
/// 仍然够点，也给输入框让出宽度（窄屏 + 1.6 倍字体的溢出用例守着这条线）。
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
      // **不要接管焦点**：这一对按钮一按，编辑会话就结束了，而 `IconButton`
      // 默认会 `requestFocus` —— 于是"提交时 unfocus"立刻被它自己抢回去，
      // 焦点留在一个即将被换掉的按钮上（实机表现：确认之后键盘不收）。
      // 关掉之后焦点就真的放掉了，`_commit` 里那次 unfocus 才算数。
      focusNode: _NoFocusNode(),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    );
  }
}

/// 一个**永不接受焦点**的 `FocusNode`，给"按完就结束"的按钮用。
///
/// `FocusNode(skipTraversal: true)` + 覆写 `canRequestFocus` 是唯一能把
/// `IconButton` 自带的 `requestFocus` 彻底关掉的做法（`focusNode` 传 null 时
/// 它会自己造一个能聚焦的）。
class _NoFocusNode extends FocusNode {
  _NoFocusNode() : super(skipTraversal: true, canRequestFocus: false);

  @override
  bool get canRequestFocus => false;

  @override
  void requestFocus([FocusNode? node]) {
    // 什么都不做：按完就结束的按钮不该抢走输入框的焦点
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
    _scrollIntoView();
  }

  /// 把这一行滚到键盘之上（与 `InlineTextField` 同一个理由，见那边的注释）。
  void _scrollIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final target = box.localToGlobal(Offset.zero) & box.size;
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      final visibleBottom = MediaQuery.sizeOf(context).height - keyboard;
      if (target.bottom <= visibleBottom - 8) return;
      Scrollable.ensureVisible(
        context,
        alignment: 1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _collapse() {
    _controller.clear();
    _focus.unfocus();
    setState(() => _expanded = false);
  }

  /// 提交一条：**收起来**，不留着输入框继续记。
  ///
  /// 2026-09-28 实机反馈："输入完一个内容点击确认之后输入框不会消失，当手动关掉
  /// 键盘后每次切回该界面就会弹出键盘"。原来这里刻意保持展开（"像系统备忘录那样
  /// 连着记几条"），但那个便利带来的代价更大：一个常驻的、**带着焦点的**输入框
  /// 会让键盘一直挂着，页面被保活之后再切回来又是一副正在输入的样子。
  /// 要再记一条就再点一次「添加条目」—— 一次点击换掉一个常驻的键盘，划算。
  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onCreate(text);
    _collapse();
  }

  /// 展开成输入框那一行：**外面套一层 `AnimatedSize`**，
  /// 这样点「＋ 添加条目」时输入框是"长出来"的（2026-09-28 实机反馈：
  /// 输入框的展开要流畅）。壳挂在这里而不是各调用点 —— 改一处，七处都受益。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = _expanded ? _buildExpanded(theme) : _buildCollapsed(theme);
    return KeyboardDismissGuard(
      isFocused: () => _focus.hasFocus && _expanded,
      // 键盘收起 = 这次输入结束：**空的直接收起，有字的按「添加」处理**
      onKeyboardDismissed: () {
        if (_controller.text.trim().isEmpty) {
          _collapse();
          return;
        }
        _submit();
      },
      child: AnimatedSize(
        duration: expandCollapseDuration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: expandCollapseDuration,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: KeyedSubtree(key: ValueKey<bool>(_expanded), child: body),
        ),
      ),
    );
  }

  Widget _buildCollapsed(ThemeData theme) {
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

  Widget _buildExpanded(ThemeData theme) {
    {
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
}
