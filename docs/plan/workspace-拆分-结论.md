# 重构 `workspace.dart` · 结论与方案

> **前情**：2026-09-27 的全项目健康度审计把「`lib/features/workspace.dart` 是一个
> 1561 行的 God Object」列为最大的结构债（`lib/features/` 下只有这一个文件）。
> 本文记录**试过一次的失败方案**与**下一步该怎么走**，避免下次再撞同一堵墙。
> （§1 的体量数字是**当时的快照**，下方已补一行"现在多少"——别再拿它当现状。）

---

## 1. 现状与代价

| 项 | 数值 |
|---|---|
| `lib/features/workspace.dart`（2026-09-27 审计当时） | **1561 行**，11 个分区（只读视图 / 项目 / 标志色 / 灵感 / 实现清单 / 事件 / 任务 / 任务线 / 批量任务动作 / 视图偏好 / 内部） |
| 同上（**2026-10-01 复核**） | **2257 行**，12 个分区（多出「重置（2026-09-28）」那一段）—— 比审计时又长了 44% |
| 镜像的测试 | `test/core/workspace_test.dart` **2072 行**（同日复核为 **2145 行**） |
| 依赖它的调用点 | 44 个提交里几乎每个都碰过它；`lib/ui/` 与 `test/` 大面积直接调 `ws.xxx()` |

代价是真实的：**任何功能改动都要动这一个文件**；两千多行的类无法被独立测试，只能整体测；
新人（或下一个 AI 会话）要改灵感逻辑，得在两千多行里找。

---

## 2. 试过并否掉的三个方案

三方案都试过、都由 `flutter analyze` 直接否决，然后**完整回退**。记在这里，省得下次再撞。

### 2.1 `part` + `extension` —— ❌ extension 对导入方不可见

**做法**：把「实现清单」分区挪进 `lib/features/workspace_checklist.dart`，
主文件加 `part '...'`，part 文件里写 `extension WorkspaceChecklist on Workspace { ... }`。
动机是"公共 API 与调用点一个都不用动"。

**结果**：`analyze` 报 10+ 处 `undefined_method`：

```
error - The method 'addProjectItem' isn't defined for the type 'Workspace'
        - lib/ui/projects/project_checklist.dart:97
```

**原因**：**extension 不是类的成员，它必须在使用处可见**（要靠 import 进入命名空间）。
哪怕 extension 与类同属一个库，导入该库的代码也只拿到类，拿不到 extension 的方法。
两次实验（先猜是 `part` 写法问题、后改成同库 extension）**结论一致**。

### 2.2 `part` 里重新 `class Workspace {` —— ❌ 同名类会冲突，不会合并

**做法**：既然 extension 不行，就把方法原样放进 part 文件里的 `class Workspace { ... }`，
赌 Dart 会把它与主文件里的 `class Workspace` 视为同一个类。

**结果**：`analyze` 改成报**大面积** `undefined_getter` / `undefined_method`（连 `prefs`、
`liveProjects` 这种最基础的都找不到）。

**原因**：**Dart 不支持把一个类拆在多个文件里**。`part` 里再写一遍 `class Workspace`
是**另一个同名类**，与主文件那个不是同一个类型 —— 调用点拿到的仍是主文件里那个空类。

### 2.3 结论

`Workspace` 现在的形态（一个类 + 私有状态 `_docs` / `_prefs` + 私有方法 `_upsert` / `persist`）
**决定了它只能整体待在一个文件里**。想拆，就必须先动"私有状态怎么共享"这件事 ——
也就是说，**拆分的前提是重构，而不是拆分本身**。

---

## 3. 下次该怎么做（唯一可行方向）

### 方向 A：把共享状态抽成一个"文档状态"对象，再拆门面（推荐）

```dart
// workspace_state.dart —— 只装状态，不装规则
class WorkspaceState {
  final AppStorage storage;
  final Map<DocName, Document> docs;
  UiPrefs prefs;
}

// workspace_project.dart
class WorkspaceProject {
  WorkspaceProject(this._state);
  final WorkspaceState _state;
  Project addProjectItem(...) { ... }   // 直接操作 _state.docs
}

// workspace.dart —— 薄门面，把调用点原样转发
class Workspace {
  late final project = WorkspaceProject(_state);
  ...
  ProjectItem addProjectItem(String id, String text) => project.addProjectItem(id, text);
}
```

- **优点**：真正的文件级拆分；每个分区可以独立测试；门面保住全部调用点。
- **代价**：要决定哪些成员留在门面、哪些下沉；`_docs` 从私有变成"库内可见"，
  需要一次性疏通私有访问（这是**一次性的机械改动**，可由编译器逐个报错引导）。
- **工作量**：半天到一天，建议**单独一轮**做，一轮只搬一个分区。

### 方向 B：只搬"最独立"的分区，且用顶层函数

把纯函数（如 `splitImplementationLines`）与不碰 `_docs` 的算法先挪走 ——
它们不依赖任何私有状态，改动面最小。适合作为方向 A 的第一步热身。

---

## 4. 为什么现在停在这里

- 剩下那一千多行里的方法**几乎全部**直接读写 `_docs` / `_prefs` 或调 `_upsert` / `persist`，
  所以"搬走一个分区"必然要先解决**私有状态共享**这个前提；
- 这是**纯结构收益**（无功能缺陷），而审计当时（2026-09-27）599 例全绿、`analyze` 0 问题，
  **没有正在流血的伤口**（现行例数口径见 `README.md` 的开发一节，别拿这句当"现在多少"）；
- 审计里所有**数据安全**类问题（P0 ×3、P1 ×10）与**代码质量**类（Q ×10）都已修完，
  把风险预算花在"拆一个不流血的大文件"上，不如留到下次真要改 `Workspace` 时一并做
  （那时正好顺着方向 A 一次搬干净）。

**结论**：**结构债已确认、方案已定、但没有实施** —— 这是一条**知情的推迟**，不是遗漏。
