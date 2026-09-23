import 'package:flutter/material.dart';

/// 空列表占位。各页面复用同一套说法，避免每个列表各写一遍。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hintText = hint;
    final actionWidget = action;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 56, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            if (hintText != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(hintText, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            ],
            if (actionWidget != null) ...<Widget>[
              const SizedBox(height: 20),
              actionWidget,
            ],
          ],
        ),
      ),
    );
  }
}
