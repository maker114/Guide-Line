# 云函数（CloudBase）

同步写路径的唯一入口。依据《同步与云函数契约》实现。

## 结构

```
cloudfunctions/
├─ common/
│  ├─ errors.js     错误码与限额（契约 §8）
│  ├─ logic.js      ★ 纯逻辑：commitTx / getVersions / getDoc（无 SDK 依赖，可完整单测）
│  ├─ stores.js     MemoryStore（测试/假后端） + CloudBaseStore（生产）
│  └─ handler.js    会话解析 + 统一信封
├─ commitTx/index.js        唯一写入口：CAS + 事务 + 幂等
├─ getVersions/index.js     只读元数据（供轮询）
├─ getDoc/index.js          读取整包
├─ test/logic.test.js       逻辑测试（假存储，不需要云环境）
├─ cloudbaserc.json         部署配置（⚠️ 需按 CLI 版本核对）
└─ package.json
```

**为什么把逻辑与 SDK 分开**：`common/logic.js` 不 require 任何云开发 SDK，
因此事务语义、幂等重放、原子回滚都能用假存储**先测透**；
SDK 相关的不确定面被压缩到 `stores.js` + `handler.js` 两个文件里。

## 测试

```bash
cd cloudfunctions
node --test test/          # 需要 Node 18+（本机尚未安装）
```

覆盖：首次创建、跨文档 +1、**原子性（一份冲突则全部不写）**、**幂等重放不重复 +1**、
真冲突返回远端版本、账号隔离、payload 不透明、会话缺失、9 类非法入参、5 MB 上限、
`getVersions` / `getDoc` 的空文档语义。

## 部署

```bash
cd cloudfunctions
cloudbase login
cloudbase functions:deploy commitTx --force
```

`cloudbaserc.json` 采用「以 `cloudfunctions/` 为函数根、handler 写 `<函数名>/index.main`」的写法，
这样 `common/` 只有一份。⚠️ 若你所用 CLI 版本要求入口文件必须位于上传根的第一层，
改用下面这个等效办法（脚本化后提交即可）：

```powershell
# 兜底方案：把 common/ 复制进每个函数目录后再逐个部署
foreach ($f in @('commitTx','getVersions','getDoc')) {
  New-Item -ItemType Directory -Force "$f\common" | Out-Null
  Copy-Item common\*.js "$f\common\" -Force
}
```

## 集合与索引（部署后手工创建一次）

| 集合 | `_id` | 关键字段 |
|---|---|---|
| `documents` | `"<accountId>:<docName>"` | `accountId`, `name`, `version`, `updated_at`, `last_tx_id`, `payload` |

索引：`documents(accountId, name)` 唯一。
**权限**：客户端**不具备**直连权限，全部经云函数（ADR-064）。

## 待实现 / 待确认清单

- [ ] **身份三件套**（`registerAccount` / `pair` / `issueTicket`）尚未实现：
      需要先核对 CloudBase **自定义登录（custom ticket）** 的签发方式与 `uid` 设置，
      以及密码学实践（恢复码 `sha256(salt + code)`、常数时间比较、失败冷却）。
- [ ] **`[待联调确认]` 标记的 4 处**：`SYMBOL_CURRENT_ENV` 初始化、
      `getEndUserInfo()` 返回结构、事务内 `set()` 入参形态、`collection().doc().get()` 返回是数组还是单对象。
- [ ] 云函数日志只允许记录 `accountIdHash / txId / docName / version / 耗时`，**禁止 payload**。
