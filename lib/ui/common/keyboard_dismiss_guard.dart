import 'package:flutter/material.dart';

/// **键盘一收起，就收掉这次编辑会话**（2026-09-28 实机反馈，ADR-086）。
///
/// 现象：输入文本后按系统返回键收起键盘，此后**碰任何东西键盘都会重新弹出来**。
/// 原因在平台侧：返回键只关掉"输入连接"，**焦点还留在输入框上**；
/// 用户之后任何一次交互（切页签、滚动、勾选）都会让 `EditableText` 回头补一次
/// 输入连接 —— 键盘就自己回来了。
///
/// 这个控件把因果掐断：键盘收起时，如果焦点**还**在自家的输入框上，就把它放掉。
///
/// 判别"到底是收键盘还是换输入框"靠 [isFocused]：
///   · 用户点另一个输入框 → 焦点已经转走，回调里 `isFocused` 是 false
///     → **不动**（换了输入框当然要继续打字）；
///   · 用户按返回键收键盘 → 焦点仍在自己身上 → **收掉这次编辑会话**。
///
/// 只在"从有键盘到没键盘"那一次跳变上触发；已经收起时不会反复调。
///
/// ## 键盘高度只能从 `View` 上读，不能从 `MediaQuery` 上读
///
/// `Scaffold` 会把 body 那层的 `MediaQuery` 底部 insets **抹掉**
/// （`scaffold.dart` 的 `_addIfNonNull`：`resizeToAvoidBottomInset` 为真时
/// 调 `removeViewInsets(removeBottom: true)`）—— 换句话说，
/// **页面里所有 Widget 看到的 `viewInsets.bottom` 恒为 0**，
/// 拿它判断键盘有没有收起永远是"没有"。
/// 于是这里直接问引擎：`View.of(context).viewInsets`（物理像素，除以缩放比还原成逻辑像素）。
///
/// 监听走 `WidgetsBindingObserver.didChangeMetrics`：键盘高度变化只会从这里来，
/// 而且**每一条别的路都试过、只有它靠得住** ——
/// `didChangeDependencies` 只在首帧跑；`MediaQuery` 那条路被上面说的 `Scaffold` 掐断了。
class KeyboardDismissGuard extends StatefulWidget {
  const KeyboardDismissGuard({
    super.key,
    required this.isFocused,
    required this.onKeyboardDismissed,
    required this.child,
  });

  /// 自家的输入框这会儿还有没有焦点。
  final bool Function() isFocused;

  /// 键盘被收起、而焦点还在自家输入框上时调用。
  final VoidCallback onKeyboardDismissed;

  final Widget child;

  @override
  State<KeyboardDismissGuard> createState() => _KeyboardDismissGuardState();
}

class _KeyboardDismissGuardState extends State<KeyboardDismissGuard>
    with WidgetsBindingObserver {
  /// 上一次看到的键盘状态；`null` 表示还没量过第一帧。
  bool? _keyboardVisible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 立一个基准：**控件是在键盘已经弹着的时候才插进树的**（编辑器展开那一刻），
    // 不量这一下，后面收起时就没有"从有到无"可言，护栏永远不响。
    _keyboardVisible ??= _keyboardVisibleNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 当前键盘是不是弹着的（读引擎给的物理 insets）。
  bool _keyboardVisibleNow() {
    final view = View.of(context);
    return view.viewInsets.bottom / view.devicePixelRatio > 0;
  }

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    final visible = _keyboardVisibleNow();
    final previous = _keyboardVisible;
    _keyboardVisible = visible;
    // 只认"从有到无"那一次
    if (previous != true || visible) {
      return;
    }
    if (!widget.isFocused()) {
      return;
    }
    // 推到帧末：同一帧里用户可能只是点了另一个输入框 ——
    // 那时焦点已经转走，下一帧再判就对了
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (!widget.isFocused()) {
        return;
      }
      widget.onKeyboardDismissed();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
