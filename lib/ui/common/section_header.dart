import 'package:flutter/material.dart';

/// 分组标题（「更多」页等长列表用）。
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
