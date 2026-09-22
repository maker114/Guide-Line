'use strict';

/**
 * 两种存储实现。
 *
 * - MemoryStore：测试与本地假后端用，实现同样的 readDoc / runTransaction 语义，
 *   写入在事务提交时才生效，抛错即整体回滚。
 * - CloudBaseStore：生产实现，走云开发文档型数据库的**服务端事务**
 *   （事务只有 node-sdk 支持，见 CloudBase 文档「事务操作」）。
 *
 * ⚠️ CloudBaseStore 中标注 [待联调确认] 的调用形态需要在真实环境里核对一次。
 */

const COLLECTION = 'documents';

function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function key(accountId, name) {
  return `${accountId}:${name}`;
}

class MemoryStore {
  constructor(seed) {
    /** @type {Map<string, object>} */
    this.docs = new Map();
    if (seed) {
      for (const [k, v] of Object.entries(seed)) this.docs.set(k, clone(v));
    }
  }

  async readDoc(accountId, name) {
    const rec = this.docs.get(key(accountId, name));
    return rec ? clone(rec) : null;
  }

  async runTransaction(fn) {
    const snapshot = new Map();
    for (const [k, v] of this.docs.entries()) snapshot.set(k, clone(v));

    const pending = new Map();
    const tx = {
      readDoc: async (accountId, name) => {
        const k = key(accountId, name);
        if (pending.has(k)) return clone(pending.get(k));
        const rec = this.docs.get(k);
        return rec ? clone(rec) : null;
      },
      writeDoc: async (accountId, name, record) => {
        pending.set(key(accountId, name), clone(record));
      },
    };

    try {
      const result = await fn(tx);
      for (const [k, v] of pending.entries()) this.docs.set(k, v);
      return result;
    } catch (err) {
      this.docs = snapshot; // 回滚
      throw err;
    }
  }
}

function recordFromDb(doc) {
  if (!doc) return null;
  return {
    version: doc.version,
    updatedAt: doc.updated_at,
    lastTxId: doc.last_tx_id === undefined ? null : doc.last_tx_id,
    payload: doc.payload,
  };
}

function docFromRecord(accountId, name, record) {
  return {
    accountId,
    name,
    version: record.version,
    updated_at: record.updatedAt,
    last_tx_id: record.lastTxId,
    payload: record.payload,
  };
}

class CloudBaseStore {
  constructor(db) {
    this.db = db;
  }

  _id(accountId, name) {
    return key(accountId, name);
  }

  async readDoc(accountId, name) {
    // [待联调确认] 集合引用与 get() 返回形态（数组 or 单对象）
    const res = await this.db.collection(COLLECTION).doc(this._id(accountId, name)).get();
    const raw = res && res.data;
    const doc = Array.isArray(raw) ? raw[0] : raw;
    return recordFromDb(doc);
  }

  async runTransaction(fn) {
    const self = this;
    // [待联调确认] node-sdk 的服务端事务入口：db.runTransaction(async (transaction) => ...)
    return this.db.runTransaction(async (transaction) => {
      const tx = {
        readDoc: async (accountId, name) => {
          const res = await transaction.collection(COLLECTION).doc(self._id(accountId, name)).get();
          const raw = res && res.data;
          const doc = Array.isArray(raw) ? raw[0] : raw;
          return recordFromDb(doc);
        },
        writeDoc: async (accountId, name, record) => {
          // [待联调确认] 事务内 set 的入参形态（文档示例为直接传对象）
          await transaction
            .collection(COLLECTION)
            .doc(self._id(accountId, name))
            .set(docFromRecord(accountId, name, record));
        },
      };
      return fn(tx);
    });
  }
}

module.exports = { MemoryStore, CloudBaseStore, COLLECTION, key };
