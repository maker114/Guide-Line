import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../board1/inspiration_panel.dart';
import '../board1/projects_view.dart';

/// 板块一：项目与灵感（设计文档 3.2）。
/// 电脑端：**三栏**（项目树 / 项目详情 / 灵感箱），编辑优先。
class Board1Page extends StatefulWidget {
  const Board1Page({super.key, required this.app});

  final AppController app;

  @override
  State<Board1Page> createState() => _Board1PageState();
}

class _Board1PageState extends State<Board1Page> {
  String? _selectedProjectId;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 300,
          child: ProjectTreePane(
            app: widget.app,
            selectedId: _selectedProjectId,
            onSelect: (id) => setState(() => _selectedProjectId = id),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: ProjectDetailPane(app: widget.app, projectId: _selectedProjectId),
        ),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 340,
          child: InspirationPanel(
            app: widget.app,
            selectedProjectId: _selectedProjectId,
          ),
        ),
      ],
    );
  }
}
