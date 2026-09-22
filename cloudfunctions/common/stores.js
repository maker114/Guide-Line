'use strict';

/**
 * 两种存储实现。
 *
 * 两套接口：
 *   A. 文档接口（同步用）：readDoc / runTransaction(tx.readDoc, tx.writeDoc)
 *   B. 集合接口（身份用）：readOne / insertOne / updateOne / deleteOne / takeOne
 *
 * - MemoryStore：测试与本地假后端，语义与生产一致，事务提交时才生效，抛错即回滚。
 * - CloudBaseStore：生产实现，走云开发文档型数据库。
 *
 * ⚠️ 标注 [待联调确认] 的调用形态需要在真实环境核对一次。
 */

const DOC_COLLECTION = 'documents';

function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function key(accountId, name) {
  return `${accountId}:${name}`;
}

class MemoryStore {
  constructor(seed) {
    /** @type {Map<string, object>} 文档（同步） */
    this.docs = new Map();
    /** @type {Map<string, Map<string, object>>} 集合（身份等） */
    this.cols = new Map();
    if (seed) {
      for (const [k, v] of Object.entries(seed)) this.docs.set(k, clone(v));
    }
  }

  _col(name) {
    if (!this.cols.has(name)) this.cols.set(name, new Map());
    return this.cols.get(name);
  }

  // ---------- A. 文档接口 ----------

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

  // ---------- B. 集合接口 ----------

  async readOne(collection, id) {
    const rec = this._col(collection).get(id);
    return rec ? clone(rec) : null;
  }

  async insertOne(collection, doc) {
    const col = this._col(collection);
    if (col.has(doc._id)) {
      const err = new Error(`已存在：${collection}/${doc._id}`);
      err.code = 'DUPLICATE';
      throw err;
    }
    col.set(doc._id, clone(doc));
    return clone(doc);
  }

  async updateOne(collection, id, patch) {
    const col = this._col(collection);
    const cur = col.get(id);
    if (!cur) return null;
    const next = Object.assign({}, cur, clone(patch), { _id: id });
    col.set(id, next);
    return clone(next);
  }

  async deleteOne(collection, id) {
    return this._col(collection).delete(id);
  }

  /** 原子「取走」：存在则返回并删除，不存在返回 null（配对码单次使用语义） */
  async takeOne(collection, id) {
    const col = this._col(collection);
    const rec = col.get(id);
    if (!rec) return null;
    col.delete(id);
    return clone(rec);
  }
}

// ---------- CloudBase 生产实现 ----------

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

function unwrap(res) {
  const raw = res && res.data;
  return Array.isArray(raw) ? raw[0] : raw;
}

class CloudBaseStore {
  constructor(db) {
    this.db = db;
  }

  _id(accountId, name) {
    return key(accountId, name);
  }

  // ---------- A. 文档接口 ----------

  async readDoc(accountId, name) {
    // [待联调确认] get() 返回是数组还是单对象
    const res = await this.db.collection(DOC_COLLECTION).doc(this._id(accountId, name)).get();
    return recordFromDb(unwrap(res));
  }

  async runTransaction(fn) {
    const self = this;
    // [待联调确认] node-sdk 的服务端事务入口
    return this.db.runTransaction(async (transaction) => {
      const tx = {
        readDoc: async (accountId, name) => {
          const res = await transaction.collection(DOC_COLLECTION).doc(self._id(accountId, name)).get();
          return recordFromDb(unwrap(res));
        },
        writeDoc: async (accountId, name, record) => {
          // [待联调确认] 事务内 set 的入参形态（官方示例为直接传对象）
          await transaction
            .collection(DOC_COLLECTION)
            .doc(self._id(accountId, name))
            .set(docFromRecord(accountId, name, record));
        },
      };
      return fn(tx);
    });
  }

  // ---------- B. 集合接口 ----------

  async readOne(collection, id) {
    const res = await this.db.collection(collection).doc(id).get();
    return unwrap(res) || null;
  }

  async insertOne(collection, doc) {
    const existing = await this.readOne(collection, doc._id);
    if (existing) {
      const err = new Error(`已存在：${collection}/${doc._id}`);
      err.code = 'DUPLICATE';
      throw err;
    }
    // [待联调确认] 指定 _id 的创建方式（doc(id).set 或 add）
    await this.db.collection(collection).doc(doc._id).set(doc);
    return doc;
  }

  async updateOne(collection, id, patch) {
    // [待联调确认] update 的 { data } 包装形态
    await this.db.collection(collection).doc(id).update({ data: patch });
    return this.readOne(collection, id);
  }

  async deleteOne(collection, id) {
    await this.db.collection(collection).doc(id).remove();
    return true;
  }

  /** 原子「取走」：必须放在事务里，避免两个设备同时用同一个配对码 */
  async takeOne(collection, id) {
    const self = this;
    return this.db.runTransaction(async (transaction) => {
      const res = await transaction.collection(collection).doc(id).get();
      const doc = unwrap(res);
      if (!doc) return null;
      await transaction.collection(collection).doc(id).remove();
      return doc;
    });
  }
}

module.exports = { MemoryStore, CloudBaseStore, DOC_COLLECTION, key };
