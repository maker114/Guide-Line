'use strict';

/**
 * 同步三件套的**纯逻辑**（不依赖云开发 SDK，可用假存储完整测试）。
 *
 * 存储接口（store）：
 *   readDoc(accountId, name)            -> Record | null
 *   runTransaction(async (tx) => ...)   -> tx: { readDoc, writeDoc }
 *   tx.writeDoc(accountId, name, record)
 *
 * Record（内部形态，snake_case 只出现在数据库字段上，此处统一用 camelCase）：
 *   { version: int, updatedAt: int, lastTxId: string|null, payload: object }
 *
 * 铁律：
 *   1. payload 对云函数**完全不透明** —— 只当 JSON 存取，不解析、不改写、不校验业务字段；
 *   2. accountId 只来自会话，绝不来自入参；
 *   3. 跨文档写入必须在**一个事务**内「先全部校验、后全部写入」。
 */

const { AppError, Code, LIMITS } = require('./errors');

/** 四份文档的白名单（《数据契约》§5） */
const DOC_NAMES = Object.freeze([
  'projects.json',
  'inspirations.json',
  'events.json',
  'tasks.json',
]);

function assertSession(session) {
  if (!session || typeof session.accountId !== 'string' || session.accountId.length === 0) {
    throw new AppError(Code.UNAUTHENTICATED, '会话无效或已过期');
  }
}

function assertDocName(name) {
  if (typeof name !== 'string' || !DOC_NAMES.includes(name)) {
    throw new AppError(Code.INVALID, `未知文档名：${String(name)}`);
  }
}

function payloadBytes(payload) {
  return Buffer.byteLength(JSON.stringify(payload), 'utf8');
}

function emptyDoc(accountId, name) {
  return { version: 0, updatedAt: null, lastTxId: null, payload: { items: [] } };
}

function asMeta(accountId, name, record) {
  if (!record) return { version: 0, updatedAt: null };
  return { version: record.version, updatedAt: record.updatedAt };
}

/**
 * commitTx —— 唯一写入口。
 *
 * 流程（《同步与云函数契约》§4.1）：
 *   ① 事务内逐份读取当前 version
 *   ② 全部 == baseVersion → 写入 + version+1 + updated_at + last_tx_id，提交
 *   ③ 幂等：某文档 version != baseVersion 但 last_tx_id == txId → 视为「本次事务已成功」
 *   ④ 任一文档真冲突 → 全部回滚，返回 conflict + 远端版本
 */
async function commitTxLogic(store, session, input) {
  assertSession(session);

  const txId = input && input.txId;
  if (typeof txId !== 'string' || txId.length < 8) {
    throw new AppError(Code.INVALID, 'txId 缺失或非法（需为 uuid）');
  }

  const docs = input && input.docs;
  if (!Array.isArray(docs) || docs.length === 0) {
    throw new AppError(Code.INVALID, 'docs 不能为空');
  }
  if (docs.length > LIMITS.MAX_DOCS_PER_TX) {
    throw new AppError(Code.INVALID, `单次事务最多 ${LIMITS.MAX_DOCS_PER_TX} 份文档`);
  }

  const seen = new Set();
  const plan = [];
  for (const d of docs) {
    assertDocName(d && d.name);
    if (seen.has(d.name)) throw new AppError(Code.INVALID, `重复文档：${d.name}`);
    seen.add(d.name);

    if (!Number.isInteger(d.baseVersion) || d.baseVersion < 0) {
      throw new AppError(Code.INVALID, `baseVersion 非法：${d.name}`);
    }
    if (d.payload === undefined || d.payload === null) {
      throw new AppError(Code.INVALID, `payload 缺失：${d.name}`);
    }
    const bytes = payloadBytes(d.payload);
    if (bytes > LIMITS.MAX_PAYLOAD_BYTES) {
      throw new AppError(Code.INVALID, `文档超限：${d.name} ${bytes} 字节`, { bytes });
    }
    if (!d.payload || !Array.isArray(d.payload.items)) {
      throw new AppError(Code.INVALID, `payload.items 必须是数组：${d.name}`);
    }
    plan.push({ name: d.name, baseVersion: d.baseVersion, payload: d.payload, bytes });
  }

  return store.runTransaction(async (tx) => {
    // ① 先全读
    const current = [];
    for (const d of plan) {
      current.push(await tx.readDoc(session.accountId, d.name));
    }

    // ③ 幂等判定：全部文档要么可直接写，要么已由本 txId 写过
    for (let i = 0; i < plan.length; i += 1) {
      const want = plan[i];
      const cur = current[i];
      const curVersion = cur ? cur.version : 0;
      const alreadyByThisTx = cur !== null && cur.lastTxId === txId && curVersion !== want.baseVersion;
      if (curVersion !== want.baseVersion && !alreadyByThisTx) {
        const remote = {};
        for (let k = 0; k < plan.length; k += 1) {
          remote[plan[k].name] = asMeta(session.accountId, plan[k].name, current[k]);
        }
        // ④ 返回而非抛出：事务内不写入任何内容，天然保持原子性
        return { conflict: true, remote };
      }
    }

    // ② 后全写
    const now = Date.now();
    const versions = {};
    for (let i = 0; i < plan.length; i += 1) {
      const want = plan[i];
      const cur = current[i];
      const curVersion = cur ? cur.version : 0;
      const alreadyWritten = cur !== null && cur.lastTxId === txId && curVersion !== want.baseVersion;
      if (alreadyWritten) {
        versions[want.name] = curVersion; // 不重复 +1
        continue;
      }
      const nextVersion = curVersion + 1;
      await tx.writeDoc(session.accountId, want.name, {
        version: nextVersion,
        updatedAt: now,
        lastTxId: txId,
        payload: want.payload,
      });
      versions[want.name] = nextVersion;
    }
    return { conflict: false, versions };
  });
}

/** getVersions —— 只读元数据，供轮询探测（《同步与云函数契约》§4.2） */
async function getVersionsLogic(store, session) {
  assertSession(session);
  const docs = {};
  for (const name of DOC_NAMES) {
    const cur = await store.readDoc(session.accountId, name);
    docs[name] = asMeta(session.accountId, name, cur);
  }
  return { docs };
}

/**
 * getDoc —— 读取整包（《同步与云函数契约》§4.3）
 * 尚未创建的文档直接返回 version=0 + 空 items（等价于「空文档」），
 * 让客户端少一个错误分支；NOT_FOUND 只留给未知文档名。
 */
async function getDocLogic(store, session, input) {
  assertSession(session);
  const name = input && input.name;
  assertDocName(name);
  const cur = await store.readDoc(session.accountId, name);
  const doc = cur || emptyDoc(session.accountId, name);
  return {
    name,
    version: doc.version,
    updatedAt: doc.updatedAt,
    payload: doc.payload,
  };
}

module.exports = {
  DOC_NAMES,
  commitTxLogic,
  getVersionsLogic,
  getDocLogic,
  payloadBytes,
};
