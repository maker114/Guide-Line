# 更新日志

本文件记录 GuideLine 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循本项目定义的 `主.次.修订` 三段式规则：

| 位 | 含义 | 归入该位的改动 |
|---|---|---|
| 第一位（主） | 软件重构 | 结构调整、模块拆分/下沉、流程或接口重做、大范围重写 |
| 第二位（次） | 新功能添加 | 新增能力、新增界面/入口/参数 |
| 第三位（修订） | bug 修复 / 外观修复 | 缺陷修正、文案与提示修正、样式与布局调整 |

补充约定：

- 一次改动同时包含多类时，按最高位那一类升级。
- 纯粹的重构、新功能、修复各自只动对应的一位。
- 界面外观类改动一律走修订位：配色、材质、透明度、模糊、圆角、间距、文案，
  以及随之增补的配色预设与参数滑杆，均按 **修订位** 处理。
  只有新增窗口、新增流程或新增对外入口，才升 **次位**。
- 日期一律使用 `YYYY-MM-DD` 格式。

---

## [Unreleased]

### Added

- **电脑端 UI（M6 第一批）**：应用装配 + 真实视图接上数据层
  - `lib/platform/data_directory.dart`：Windows 用 `%APPDATA%\GuideLine`（**不引入 path_provider**，
    手机端以后再补分支）
  - `lib/app/app_controller.dart`：`ChangeNotifier` 装配（加载本地数据 + 启动告警 +
    把 `RuleViolation` 变成可读文案 + 导出/导入门面 + 同步状态），**零新增依赖**
  - 板块一（`lib/ui/board1/`）：**三栏**（项目树 / 项目详情 / 灵感箱）——
    项目树支持层级、折叠（`ui_prefs`）、三态切换（完成条件未满足时禁用并解释原因）、
    新建子项目、归档（含级联）、删除（二次确认显示影响范围）；
    项目详情可编辑目的/实现/日期并显示元信息；
    灵感箱支持速记、分配、丢弃、删除，以及**上下分区合并编辑器**（上区可编辑、下区只读对照）
  - **归档区**（`lib/ui/archive/`）：已归档 / 已丢弃 / 已合并 / 回收站 / 本地草稿五个分区，
    提供取消归档、恢复、撤销合并、**彻底删除**（二次确认 + 墓碑骨架化）
  - **设置页**（`lib/ui/settings/`）：数据目录、四份文档版本号、本地统计、同步状态、
    导出（写到 `数据目录/exports/`，路径可复制）、导入（预检 → 判定表 → 应用，冲突项保留本地并落草稿）
  - 聚合视图：今天/本周到期（含逾期标记）、全部任务
  - 启动失败页：读盘/解析异常时给出可读错误并明确"数据未被修改"
- **回收站恢复**（`Workspace.restoreFromTrash`）：项目/任务/事件连同级联进来的后代一起恢复
- **同步引擎**（`lib/sync/sync_engine.dart`，17 个用例）：把 `SyncBackend` 与本地 `Workspace` 接起来 ——
  固定顺序 ⓪ 校验会话 → ① 补发 `pending_tx`（跨文档**只发一次** `commitTx`）→ ② 推送脏文档 →
  ③ 先探测版本再拉取整包 → ④ 落盘 `sync_state`；含冷启动判定表（两边空 / 拉取 / 推送 / **交给用户选**）、
  冲突裁决（以云端为准时本地改动先落草稿；以本地为准时用远端版本号作新 base 重推）、
  离线与凭证失效的状态上报（UI 直接消费）
- **零第三方搬移：导出 / 导入**（`lib/features/portability.dart`，10 个用例）：
  `.json.gz`（用 `dart:io` 自带 gzip，**不引入任何依赖**），含 4 份文档与版本号、
  **连墓碑与墓碑骨架一起带走**（否则导入后已删数据会"复活"）；
  导入前先 `preview` 逐份判定（identical / takeIncoming / keepLocal / conflict），
  **本地有未提交改动时绝不静默覆盖**，被覆盖或被保留的一侧都落草稿（`conflicts/`）。
  > 判定规则特意处理了"离线搬移时两端版本号都是 0"这一主路径：版本相同但本地干净 → 采用导入包。
- **业务逻辑层**（`lib/features/workspace.dart`）：内存单一数据源 + 全部业务操作 ——
  项目（创建/编辑/三态完成判定/双向级联归档/跨文档级联删除/移动重排）、
  灵感（捕获/分配/上下分区合并/撤销合并/丢弃恢复/删除）、
  事件（创建/完成/归档整条任务线/删除）、任务（三类结构约束/完成/移动含跨事件/删除/重排）、
  归档区推导、全局搜索、到期聚合、彻底删除（墓碑骨架化）；
  **跨文档操作在同一时刻写入 `pending_tx`**，并区分"本次操作涉及的文档"与"当前脏文档"
- **云端后端选型对比**（`docs/spec/云端后端选型对比.md`）：四条免费/低成本路线的事实、
  判定维度、需要的凭证与隐私注意（待裁定）
- **Flutter 工程骨架**：包名 `guideline`、版本 `1.0.0+1`（Flutter 3.47.5 / Dart 3.13.4），
  `--platforms=windows` 生成 Windows runner；环境变量已把 `E:\flutter\bin`、`E:\nodejs` 加入用户 PATH
- **架构边界测试**（`test/core/architecture_test.dart`）：扫描源码守护三条边界 ——
  `lib/core` 不依赖 Flutter、三层不出现 CloudBase SDK、三层不出现平台判断、依赖方向单向
- **电脑端外壳与入口**（`lib/main.dart` / `lib/ui/desktop/desktop_shell.dart`）：
  侧栏导航（两板块 + 到期聚合 + 全部任务 + 归档区 + 设置）+ 常驻同步状态位（M6 接入真实数据）
- **数据契约**（`docs/spec/数据契约.md`）：4 实体完整字段表（顺序即写出顺序）、文档外层结构、
  墓碑骨架、枚举与允许的父子组合、跨字段一致性、契约样本与回归测试规则、演进与容错规则
- **同步与云函数契约**（`docs/spec/同步与云函数契约.md`）：`SyncBackend` 接口草案、
  本地文件清单、云端集合、6 个云函数入出参、`pending_tx`、同步状态机与冲突流程、错误码表
- **v1.0.0 电脑端计划**（`docs/plan/v1.0.0-电脑端计划.md`）：范围、验收标准、里程碑 M0~M7、依赖与风险
- **契约黄金副本**（`test/contract/sample/*.json`）：4 份文档样本，覆盖可空字段、三层嵌套、
  三种 status、三类任务、归档与墓碑骨架，作为序列化逐字节比对的基准
- **云函数同步三件套**（`cloudfunctions/`）：`commitTx`（唯一写入口：CAS + 事务 + 幂等重放）、
  `getVersions`（轮询只读元数据）、`getDoc`；逻辑与 CloudBase SDK 分离，
  逻辑层可由假存储完整单测（13 个用例覆盖原子回滚、幂等、账号隔离、payload 不透明、入参校验、5 MB 上限）
- **云函数部署配置**：`cloudbaserc.json` 与 `README.md`（含待联调确认清单）
- **契约样本格式闸门**（`tools/check-contract-samples.js`）：不需要 Dart 即可校验 BOM / 换行 /
  缩进 / key 顺序 / 转义 / 外层结构 / 墓碑骨架形态
- **版本无关测试运行器**（`cloudfunctions/test/run.js`）：在只有 Node 14/16 的环境下
  也能运行 `node:test` 风格用例，且不 spawn 子进程
- **身份五件套云函数**（`cloudfunctions/common/identity.js` + 5 个入口）：
  `registerAccount`（客户端给恢复码、服务端给 accountId，只存 `sha256(salt+code)`）、
  `createPairingCode`（6 位一次性码，新码使旧码失效）、`pair`（次端换同一账号的票）、
  `issueTicket`（换机 / 重装）、`rotateRecoveryCode`（旧码立即失效）
- **登录票签发与运行时装配**（`cloudfunctions/common/ticket.js` / `runtime.js`）：
  把唯一无法离线验证的外部契约集中到一处，未核对前**显式抛错**，不发假票
- **core 数据层**（`lib/core/`，16 个 Dart 文件）：4 实体模型（字段顺序即契约顺序 + 未知字段透传）、
  规范化 JSON 出口（唯一序列化点）、文档解析（墓碑骨架优先识别 + 容错降级）、
  树索引（层级 / 后代 / 环路 / 深度校验）、完成判定（判定域 + 反向传播）、
  级联（删除 / 双向归档 / 项目删除的跨文档影响面 / 移动校验）、归档区四分区、
  UUID v4 与恢复码生成
- **Dart 静态契约闸门**（`tools/check-dart-contract.js`）：括号平衡 + 各实体 `toJson()` 字段顺序
  与《数据契约》§3 逐字段比对 + `knownKeys` 一致性（在无 SDK 时挡住"顺序错了编译器也不报"的风险）
- **本地存储层**（`lib/core/store/`）：`AtomicFile`（写 `.tmp` → flush → rename，损坏文件隔离为
  `.corrupt.<ts>` 而非静默重建）、`LocalPaths`（4 文档 + 元数据 + 草稿目录）、
  `LocalStore`（启动加载报告 + 原子落盘 + 冲突草稿）、`SyncState`（**不存版本号**）、
  `PendingTx`（跨文档事务重放凭据）、`UiPrefs`（折叠状态等，不参与同步）
- **同步接口与假后端**（`lib/sync/`）：`SyncBackend` 五方法接口（payload 以原始 JSON 字符串穿过，
  不含任何 CloudBase 类型）、`FakeSyncBackend`（忠实复刻 CAS / 事务原子性 / 幂等重放，并统计调用次数）

### Verified

- 云函数逻辑实测 **26/26 通过**（Node v16.13.2）：
  - 同步 13 例：首次创建、跨文档 +1、原子性（一份冲突则全部不写）、幂等重放不重复 +1、
    真冲突返回远端版本、账号隔离、payload 不透明、会话缺失、9 类非法入参、5 MB 上限、空文档语义
  - 身份 13 例：accountId 形态与明文恢复码绝不落库、恢复码归一化、需会话校验、6 位码 + 5 分钟 TTL、
    新码使旧码失效、配对码单次使用、过期码拒绝、失败 5 次冷却 10 分钟、恢复码换票、
    账号不存在与恢复码错误返回同一错误（不泄漏存在性）、重置恢复码后旧码失效
- 4 份契约样本通过格式闸门（共 20 条记录，含 2 个墓碑骨架）
- 16 个 Dart 文件通过静态契约闸门（括号平衡、行尾、`toJson` 字段顺序、`knownKeys`）
- **`flutter analyze`：No issues found**（含 `unawaited_futures: error` 等更严格的规则集）
- **`flutter test`：62/62 全部通过** —— 契约样本逐字节回归、容错降级、树索引、
  完成判定与反向传播、级联与移动校验、归档区四分区、存储原子写与崩溃隔离、
  假后端 CAS/原子性/幂等、架构边界 6 例
- **Windows release 构建成功**：`flutter build windows --release` →
  `build\windows\x64\runner\Release\guideline.exe`（含 20.29 MB `flutter_windows.dll`）

### Fixed

- `FakeSyncBackend` 的 `_tick()` 忘记 `await`，导致离线/失效错误逃逸为未处理异步异常
  （同时开启 `unawaited_futures: error` 防止复发）
- `rules_test` 的反向传播用例混用了两个 API：把"节点自身变为非终态"用成了"插入新节点"

### Changed

- `analysis_options.yaml`：在 `flutter_lints` 之上开启 `unawaited_futures: error`、
  `prefer_single_quotes`、`always_declare_return_types`、`prefer_final_locals`、`directives_ordering`
- 架构设计 §5.1 明确**版本号唯一存放于本地文档外层**，`sync_state.json` 只存同步元数据，
  避免版本号两处存放（与《数据契约》§2 对齐）

---

## [0.0.0] - 2026-09-22

首个版本。本版本**不含任何应用功能**，仅建立项目基建与工程规范，
为后续开发提供版本管理、提交规范与变更记录的载体。

### Added

- **仓库初始化**：在工作区根 `E:\Guide Line\` 建立 Git 仓库，默认分支 `main`
  （此前误建于 `E:\DSH WorkSpace\outputs\`，本版已纠正，规范不变）
- **忽略规则**（`.gitignore`）：覆盖 Dart/Flutter 构建产物、Android/iOS/Windows
  平台生成文件、IDE 配置、系统文件、证书与密钥、日志与临时文件
- **Git 属性**（`.gitattributes`）：统一换行符（源码 LF、Windows 脚本 CRLF），
  标记二进制文件禁止转换，标注生成文件避免语言统计干扰
- **更新日志**（`CHANGELOG.md`）：采用 Keep a Changelog 规范
- **版本号规则**：确立 `主.次.修订` 三段式语义，并绑定提交类型
  （`refactor` → 主位，`feat` → 次位，`fix`/`to`/`style` → 修订位）
- **架构设计文档**（`docs/architecture/双端软件架构设计.md`）：录入双端架构设计第 13 版，
  含云端改用腾讯云开发 CloudBase、配对码身份方案、跨文档事务、归档区、主线任务结构等裁定

### Security

- 忽略规则中显式排除证书与密钥类文件（`*.jks`、`*.keystore`、`*.p12`、
  `*.pem`、`key.properties`、`secrets.json`、`.env*`），防止凭证误入库
