# 云函数（CloudBase）

GuideLine 的全部云端逻辑。依据《同步与云函数契约》实现。

## 结构（8 个函数）

| 分类 | 函数 | 会话 | 职责 |
|---|---|---|---|
| 同步 | `commitTx` | 需要 | **唯一写入口**：事务内 CAS + 写入 + `version+1` + `last_tx_id` |
| 同步 | `getVersions` | 需要 | 只读元数据（轮询专用） |
| 同步 | `getDoc` | 需要 | 读取整包 payload |
| 身份 | `registerAccount` | 公开 | 首端建档：客户端给恢复码，服务端给 accountId |
| 身份 | `createPairingCode` | 需要 | 首端生成 6 位一次性配对码 |
| 身份 | `pair` | 公开 | 次端用配对码换取同一 accountId 的登录票 |
| 身份 | `issueTicket` | 公开 | 换机 / 重装：用恢复码换登录票 |
| 身份 | `rotateRecoveryCode` | 需要 | 重置恢复码（建议**不部署或不对公网开放**） |

```
cloudfunctions/
├─ common/
│  ├─ errors.js     错误码与限额（契约 §8）
│  ├─ logic.js      ★ 同步纯逻辑：commitTx / getVersions / getDoc
│  ├─ identity.js   ★ 身份纯逻辑：注册 / 配对 / 换票 / 重置恢复码
│  ├─ stores.js     MemoryStore（测试/假后端） + CloudBaseStore（生产）
│  ├─ handler.js    会话解析 + 统一信封（含「公开」与「需会话」两类入口）
│  ├─ runtime.js    SDK 初始化与依赖注入的唯一落点
│  └─ ticket.js     登录票签发（唯一无法离线验证的外部契约）
├─ commitTx/ getVersions/ getDoc/
├─ registerAccount/ createPairingCode/ pair/ issueTicket/ rotateRecoveryCode/
├─ test/logic.test.js  test/identity.test.js  test/run.js
├─ cloudbaserc.json         部署配置（⚠️ 需按 CLI 版本核对）
└─ package.json
```

**为什么把逻辑与 SDK 分开**：`common/logic.js` 与 `common/identity.js` 不 require 任何云开发 SDK，
所以事务语义、幂等重放、恢复码哈希、配对码单次性、失败冷却都能用假存储**先测透**；
SDK 的不确定面被压缩到 `stores.js`、`runtime.js`、`handler.js`、`ticket.js` 四个文件。

## 测试

```bash
cd cloudfunctions
node test/run.js          # 任意 Node 14+（本机用 Adobe 捆绑的 v16.13.2 即可跑）
node --test test/         # Node 18+ 的原生运行器（等价）
```

**26 个用例**，两组：

- **同步（13）**：首次创建、跨文档 +1、**原子性（一份冲突则整份事务不写）**、
  **幂等重放不重复 +1**、真冲突返回远端版本、账号隔离、payload 不透明、会话缺失、
  9 类非法入参、5 MB 上限、`getVersions` / `getDoc` 的空文档语义。
- **身份（13）**：accountId 形态与**明文恢复码绝不落库**、恢复码归一化、需会话校验、
  6 位码 + 5 分钟 TTL、新码使旧码失效、**配对码单次使用**、过期码拒绝、
  **失败 5 次后冷却 10 分钟**、恢复码换票、**账号不存在与恢复码错误返回同一错误**（不泄漏存在性）、
  重置恢复码后旧码失效。

## 集合与索引（部署后手工创建一次）

| 集合 | `_id` | 关键字段 |
|---|---|---|
| `documents` | `"<accountId>:<docName>"` | `accountId`, `name`, `version`, `updated_at`, `last_tx_id`, `payload` |
| `accounts` | `accountId` | `recoveryHash`, `recoverySalt`, `activePairingCode`, `createdAt`, `lastSeenAt` |
| `devices` | `"<accountId>:<deviceId>"` | `accountId`, `deviceId`, `name`, `lastSeenAt`, `revoked` |
| `pairing_codes` | 6 位码 | `accountId`, `expiresAt`（建议加 TTL 索引） |
| `cooldowns` | `"<kind>:<subject>"` | `count`, `until`, `updatedAt` |

索引：`documents(accountId, name)` 唯一；`pairing_codes(expiresAt)` TTL。
**权限**：客户端**不具备**任何直连权限，全部经云函数（ADR-064）。

## 部署

### 为什么需要先打包

源码里各函数的 `index.js` 引用共享目录（`require('../common/xxx')`），而云函数的代码根
只能是一份自包含代码。所以先打包，把 `../common/` 改写成 `./common/` 并把 `common/` 复制进去：

```powershell
cd cloudfunctions
node tools/pack.js                       # 生成 dist/cli/<函数名>/ 与 dist/web/<函数名>/
foreach ($fn in @('commitTx','getVersions','getDoc','registerAccount','createPairingCode','pair','issueTicket','rotateRecoveryCode')) {
  Compress-Archive -Path "dist\web\$fn\*" -DestinationPath "dist\web\$fn.zip" -Force
}
```

产物（`dist/` 不入库）：

| 目录 | 用途 |
|---|---|
| `dist/cli/<函数名>/` | CLI 声明式部署用（`cloudbaserc.json` 的 `dir` 指向它） |
| `dist/web/<函数名>.zip` | **网页控制台**「上传 ZIP 包」用（ZIP 根就是 `index.js` + `common/`） |

---

### 路线 A：网页控制台（推荐先用这条，无需装 CLI）

**① 开通环境**
1. 打开 <https://tcb.cloud.tencent.com/dev>（或腾讯云控制台搜「云开发 CloudBase」）
2. 首次使用需**实名认证**
3. 「新建环境」→ 计费方式选**按量计费**（个人用量极低；先确认当前免费额度政策）
   → 地域选 **上海** → 起个名字（如 `guideline-prod`）
4. 建好后在**环境概览**记下 **环境 ID**（形如 `guideline-prod-1g2h3j4k5l6m7n`）

**② 拿客户端要用的 Publishable Key**
- 「环境 → API Key 配置」→ 生成 **Publishable Key**（可公开，给客户端做匿名访问公开资源）
- ⚠️ **Secret Key 绝不能进 App**（安全红线，见设计文档 §7.4）

**③ 建集合与索引**（「数据库 → 集合管理」）
1. 新建 5 个集合：`documents`、`accounts`、`devices`、`pairing_codes`、`cooldowns`
2. `documents` 建索引：`accountId`(升序) + `name`(升序)，**唯一**
3. `pairing_codes` 建索引：`expiresAt`(升序)，**非唯一**
4. 「数据库 → 权限设置」把每个集合设为**仅管理端可读写**（客户端不直连，ADR-064）

**④ 部署 8 个云函数**
对每个函数名重复（`commitTx` / `getVersions` / `getDoc` / `registerAccount` /
`createPairingCode` / `pair` / `issueTicket` / `rotateRecoveryCode`）：
1. 「云函数 → 新建云函数」→ 函数名称填该名字 → **运行环境选 `Nodejs20.19`**
2. 代码上传方式选**本地上传 ZIP 包** → 选 `cloudfunctions/dist/web/<函数名>.zip`
3. **函数入口填 `index.main`**（超时：`commitTx`/`getDoc`/`pair`/`issueTicket`/`registerAccount` 用 10 秒，其余 5 秒）
4. 保存并等部署完成；`rotateRecoveryCode` 建议**不要对外暴露**（见下）

**⑤ 开自定义登录（身份函数的最后一块拼图）**
1. 「身份认证 → 登录方式 → 自定义登录」→ 开启 → **下载私钥文件**
2. 私钥**不入库、不进聊天**：在云函数「函数配置 → 环境变量」里配置（建议键名 `CUSTOM_LOGIN_KEY`）
3. ⚠️ 这一步对应代码里的待确认项：`ticket.js` 目前会**显式抛错**，等私钥就位后我改成用私钥签 JWT

**⑥ 冒烟验证**
- 「云函数 → commitTx → 测试」传 `{}` → 期望返回
  `{"ok":false,"code":"UNAUTHENTICATED",...}`：说明函数已部署且鉴权生效
- 对 `getVersions`、`getDoc` 同样各测一次

---

### 路线 B：CloudBase CLI（熟练后更快）

```powershell
npm.cmd install -g @cloudbase/cli      # 注意：PowerShell 默认禁止 npm.ps1，用 npm.cmd 绕过
cloudbase login                        # 扫码登录，无法代做
cd cloudfunctions
node tools/pack.js                     # 先生成 dist/cli/<函数名>/
cloudbase functions:deploy commitTx    # 逐个部署；或按 cloudbaserc.json 声明式部署
```

`cloudbaserc.json` 的 `envId` 目前是占位符 `{{env.CLOUDBASE_ENV_ID}}`，
填入真实环境 ID（或设同名环境变量）后即可声明式部署。

## 待联调确认清单

- [ ] **`ticket.js`**：CloudBase **自定义登录**的建票方式（私钥签 JWT 的字段与有效期）；
      `uid` 是否可直接设为我们的 `accountId`。
      （未核对前它会**显式抛错**，不会静默发假票。）
- [ ] **`runtime.js`**：`cloudbase.SYMBOL_CURRENT_ENV` 的初始化写法。
- [ ] **`handler.js`**：`app.auth().getEndUserInfo()` 的调用形态与返回结构。
- [ ] **`stores.js`**（4 处）：事务内 `set()` 入参形态、`collection().doc().get()` 返回数组还是单对象、
      `update({data})` 包装形态、`takeOne` 的事务删读取实现。
- [ ] 云函数日志只允许记录 `accountIdHash / txId / docName / version / 耗时`，**禁止 payload 与恢复码**。
