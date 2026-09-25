/// 项目标志色的色板（**唯一的定义处**）。
///
/// 放 core 而不是 ui，是因为有**两个**使用方，而它们不能互相依赖：
///   · `lib/ui` 的取色器要把它列出来让用户挑；
///   · `lib/features` 的 `Workspace` 要在新建项目时自动分配一个。
/// 架构约束是"features 不依赖 ui"（`test/core/architecture_test.dart` 守着），
/// 所以这份数据只能待在两边都能用的 core。
///
/// 色值取自用户给的 12 个 Hex：低饱和的灰调彩色，
/// 用来在小面积上互相区分，又不抢内容。
abstract final class ProjectPalette {
  static const List<String> hexes = <String>[
    '#AD6868', // 陶红
    '#B87F56', // 赭
    '#DECF7C', // 麦黄
    '#CCE8B6', // 嫩绿
    '#87C57E', // 草绿
    '#87C7AD', // 松石
    '#78D2CA', // 青
    '#A9BFD5', // 雾蓝
    '#8280AE', // 灰紫
    '#DAC1E0', // 藕荷
    '#A56EA9', // 紫
    '#A85780', // 梅红
  ];
}
