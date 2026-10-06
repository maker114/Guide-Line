# 重构 `workspace.dart` · 结论与方案

> **前情**：2026-09-27 的全项目健康度审计把「`lib/features/workspace.dart` 是一个
> 1561 行的 God Object」列为最大的结构债（`lib/features/` 下只有这一个文件）。
> 本文记录**试过一次的失败方案**与**下一步该怎么走**，避免下次再撞同一堵墙。
> （§1 的体量数字是**当时的快照**，下方已补一行"现在多少"——别再拿它当现状。）
>
> ⚠️ **2026-10-01 复核时发现："1561 行"这个数与实际对不上。** 按提交逐版量
> （落成临时文件后的 LF 字节数，不用经过代码页的 `Get-Content`）：这个文件
> 2026-09-23 建起来时是 **1053 行**，09-26 是 1716，**09-27 当天是 2014**。
> 也就是说 §1 与下文那句"又长了 44%"**都建立在一个复核不出来的基数上** ——
> 这个文件似乎从未处于 1561 行。真实情况比 44% 更重：**九天里从 1053 涨到 2257**。
> 原句按 §8「历史条目不改写」保留，但**别再引用 1561 与 44% 这两个数**。

---

## 1. 现状与代价

| 项 | 数值 |
|---|---|
| `lib/features/workspace.dart`（2026-09-27 审计当时，写成 1561 行） | 原话保留：11 个分区（只读视图 / 项目 / 标志色 / 灵感 / 实现清单 / 事件 / 任务 / 任务线 / 批量任务动作 / 视图偏好 / 内部）。**同日实测是 2014 行**（见开头的复核说明） |
| 同上（**2026-10-01 复核**） | **2257 行**，12 个分区（多出「重置（2026-09-28）」那一段）。原文写"比审计时又长了 44%"—— **该增幅不成立**（1561 对不上，2014→2257 是 +12%）；但把起点放回建立那天，**1053 → 2257 是九天翻了一倍多** |
| 同上（**2026-10-01 本轮，方向 A 第一步做完之后**） | **2267 行**（+10，是转发成员与 export 的代价）；另新增 `lib/features/workspace_state.dart` **88 行** |
| 镜像的测试 | `test/core/workspace_test.dart` **2072 行**（同日复核为 **2145 行**） |
| 依赖它的调用点 | 44 个提交里几乎每个都碰过它；`lib/ui/` 与 `test/` 大面积直接调 `ws.xxx()`。2026-10-01 实测：`lib/ui` + `lib/app` 上 **228 处**，`workspace_test.dart` 里 **669 处** |

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

> ✅ **2026-10-01：方向 A 的第一步已经落地**（提交"把 Workspace 的共享状态搬进
> `workspace_state.dart`"，版本 2.0.0）。做出来的形状与下面的草案有一处差别，
> 记在这里免得下一轮照草案重新猜：
>
> - 草案把状态对象写成"只装状态"的 `WorkspaceState`—— **实际也是**，但它同时收下了
>   原来的私有改动通道 `_upsert`（公开为 `WorkspaceState.upsert`）。理由：`upsert`
>   只是"按 id 换掉或塞进去"，不含业务规则，而它被 **61 处**调用 —— 不跟着状态一起走，
>   那些调用方一个都搬不动；
> - `Workspace` 里仍保留 `_docs` / `_prefs` / `_upsert` 三个**转发成员**，
>   指向状态容器。这样 228 个外部调用点与 669 处测试调用**一行都不用改** ——
>   这是"零行为改动"的实现方式，也是这一步唯一的验收依据（830 次测试全绿）；
> - `persist()` / `snapshotNow()` **没有跟着搬**：它们要现算 `buildStoreFile()`，
>   属于门面自己的事，留给"落盘调度"那一块一起走。

```dart
// workspace_state.dart —— 只装状态，不装规则（已完成，实际签名见该文件）
class WorkspaceState {
  final AppStorage storage;
  final Map<DocName, Document> documents;
  UiPrefs prefs;
  Document documentOf(DocName name);
  void upsert(DocName name, Entity entity);   // 原来的 Workspace._upsert
}

// workspace_project.dart —— 下一步：按域搬，一轮一块（尚未开始）
class WorkspaceProject {
  WorkspaceProject(this._state);
  final WorkspaceState _state;
  Project addProjectItem(...) { ... }   // 直接操作 _state.documents
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
- **本轮的实际代价**：`workspace.dart` **没有变短**（2257 → 2267，多了转发成员与
  export 的 10 行）。这是预期内的 —— 状态搬家本身不产生可读性收益，
  它只是让后面每一块搬得动。**别把这一步当成果汇报。**

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

> ⚠️ **2026-10-01 更新：上面这段"没有实施"已经不成立。** 方向 A 的**第一步**
> （共享状态搬家，§3 那一节）当天就做完了，版本 2.0.0。原文按 §8 保留，
> 但请连着读下面这两句：
>
> - **做完的只是地基**：89 个业务方法**一个都还没搬**，`workspace.dart` 反而多了 10 行。
>   所以 §4 那段"为什么停在这里"的**理由依然有效**，只是前提从
>   "私有状态挡着"变成了"地基已经好了，缺的是下一轮的时间"；
> - 本文 §1 里"审计当时 599 例"那句早已过期（写"现行例数口径见工程说明"
>   是当时就留好的口子 —— 2026-10-06 起那一节在 `docs/工程说明.md` §4，
>   原先在 README 的开发一节）。2026-10-01 实测是 **830 次通过 / 声明 812 例**，
>   而且这个数现在**有测试守着**了 —— 见 `docs_consistency_test.dart`。
