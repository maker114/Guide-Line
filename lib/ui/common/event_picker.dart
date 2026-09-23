import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/models/event.dart';

/// 事件选择器（底部弹出）。返回 `null` 表示取消。
Future<String?> pickEvent(
  BuildContext context,
  AppController app, {
  required String title,
  String? excludeId,
}) {
  final events = app.ws.liveEvents
      .where((e) => !e.archived && e.id != excludeId)
      .toList(growable: false)
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
          ),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text('没有可选的事件'),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final Event event in events)
                    ListTile(
                      leading: const Icon(Icons.timeline, size: 18),
                      title: Text(event.name),
                      onTap: () => Navigator.of(sheetContext).pop(event.id),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
