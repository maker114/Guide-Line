import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../board1/inspiration_panel.dart';
import '../board1/projects_view.dart';

/// 板块一：项目与灵感（设计文档 3.2）。
/// 电脑端：**三栏**（项目树 / 项目详情 / 灵感箱），编辑优先。
///
/// 选中项由外层（外壳）持有，这样全局搜索可以直接跳到某个项目。
class Board1Page extends StatelessWidget {
  const Board1Page({
    super.key,
    required this.app,
    required this.selectedProjectId,
    required this.onSelect,
  });

  final AppController app;
  final String? selectedProjectId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 300,
          child: ProjectTreePane(
            app: app,
            selectedId: selectedProjectId,
            onSelect: onSelect,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: ProjectDetailPane(app: app, projectId: selectedProjectId),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 340,
          child: InspirationPanel(app: app, selectedProjectId: selectedProjectId),
        ),
      ],
    );
  }
}
