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

```bash
cd cloudfunctions
cloudbase login
cloudbase functions:deploy commitTx --force
```

`cloudbaserc.json` 采用「以 `cloudfunctions/` 为函数根、handler 写 `<函数名>/index.main`」的写法，
这样 `common/` 只有一份。⚠️ 若你所用 CLI 版本要求入口文件位于上传根的第一层，
用下面的兜底方案（复制 `common/` 进各函数目录后再逐个部署）：

```powershell
foreach ($f in @('commitTx','getVersions','getDoc','registerAccount','createPairingCode','pair','issueTicket','rotateRecoveryCode')) {
  New-Item -ItemType Directory -Force "$f\common" | Out-Null
  Copy-Item common\*.js "$f\common\" -Force
}
```

## 待联调确认清单

- [ ] **`ticket.js`**：CloudBase **自定义登录**的建票 API 名称与入参；`uid` 是否可直接设为我们的
      `accountId`；ticket 有效期与单次性。（未核对前它会**显式抛错**，不会静默发假票。）
- [ ] **`runtime.js`**：`cloudbase.SYMBOL_CURRENT_ENV` 的初始化写法。
- [ ] **`handler.js`**：`app.auth().getEndUserInfo()` 的调用形态与返回结构。
- [ ] **`stores.js`**（4 处）：事务内 `set()` 入参形态、`collection().doc().get()` 返回数组还是单对象、
      `update({data})` 包装形态、`takeOne` 的事务删读取实现。
- [ ] 云函数日志只允许记录 `accountIdHash / txId / docName / version / 耗时`，**禁止 payload 与恢复码**。
