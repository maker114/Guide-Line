'use strict';

/**
 * 同步三件套的逻辑测试（不需要 Node 之外任何依赖，也不需要云环境）。
 *
 *   node --test test/
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const { MemoryStore, key } = require('../common/stores');
const { commitTxLogic, getVersionsLogic, getDocLogic } = require('../common/logic');
const { Code, LIMITS } = require('../common/errors');

const ACC = 'acc-primary';
const OTHER = 'acc-other';
const SESSION = { accountId: ACC };
const TX = '11111111-2222-4333-8444-555555555555';
const TX2 = '99999999-8888-4777-8666-555555555555';

const doc = (name, baseVersion, items) => ({ name, baseVersion, payload: { items: items || [] } });
const rec = (id) => ({ id, deleted: false });

function seeded(accountId, name, version, items) {
  return new MemoryStore({
    [key(accountId, name)]: {
      version,
      updatedAt: 1700000000000,
      lastTxId: 'seed-tx-0000000000',
      payload: { items: items || [] },
    },
  });
}

test('首次提交：创建文档并返回 version = 1，写入 last_tx_id', async () => {
  const store = new MemoryStore();
  const out = await commitTxLogic(store, SESSION, {
    txId: TX,
    docs: [doc('projects.json', 0, [rec('p1')])],
  });

  assert.equal(out.conflict, false);
  assert.deepEqual(out.versions, { 'projects.json': 1 });

  const saved = await store.readDoc(ACC, 'projects.json');
  assert.equal(saved.version, 1);
  assert.equal(saved.lastTxId, TX);
  assert.deepEqual(saved.payload.items, [rec('p1')]);
});

test('跨文档提交：两份文档同时 +1', async () => {
  const store = new MemoryStore();
  const out = await commitTxLogic(store, SESSION, {
    txId: TX,
    docs: [doc('projects.json', 0, [rec('p1')]), doc('inspirations.json', 0, [rec('i1')])],
  });

  assert.equal(out.conflict, false);
  assert.deepEqual(out.versions, { 'projects.json': 1, 'inspirations.json': 1 });
});

test('原子性：任一文档冲突则整笔事务都不写入', async () => {
  const store = seeded(ACC, 'projects.json', 3, [rec('p-old')]);
  const out = await commitTxLogic(store, SESSION, {
    txId: TX,
    docs: [doc('projects.json', 2, [rec('p-new')]), doc('inspirations.json', 0, [rec('i1')])],
  });

  assert.equal(out.conflict, true);
  assert.deepEqual(out.remote['projects.json'], { version: 3, updatedAt: 1700000000000 });

  const untouched = await store.readDoc(ACC, 'projects.json');
  assert.equal(untouched.version, 3);
  assert.deepEqual(untouched.payload.items, [rec('p-old')]);

  // 关键：另一份文档绝不能留下半成品
  assert.equal(await store.readDoc(ACC, 'inspirations.json'), null);
});

test('幂等：同一 txId 重放不再 +1', async () => {
  const store = new MemoryStore();
  const first = await commitTxLogic(store, SESSION, {
    txId: TX,
    docs: [doc('projects.json', 0, [rec('p1')])],
  });
  assert.deepEqual(first.versions, { 'projects.json': 1 });

  // 模拟「响应丢失后客户端用同样的 baseVersion 重试」
  const replay = await commitTxLogic(store, SESSION, {
    txId: TX,
    docs: [doc('projects.json', 0, [rec('p1')])],
  });
  assert.equal(replay.conflict, false);
  assert.deepEqual(replay.versions, { 'projects.json': 1 }, '重放必须返回原版本，不得 +1');

  const saved = await store.readDoc(ACC, 'projects.json');
  assert.equal(saved.version, 1);
});

test('真冲突：不同 txId 且 baseVersion 落后 → conflict', async () => {
  const store = seeded(ACC, 'tasks.json', 7, []);
  const out = await commitTxLogic(store, SESSION, {
    txId: TX2,
    docs: [doc('tasks.json', 6, [rec('t1')])],
  });
  assert.equal(out.conflict, true);
  assert.equal(out.remote['tasks.json'].version, 7);
});

test('账号隔离：A 的提交对 B 不可见', async () => {
  const store = new MemoryStore();
  await commitTxLogic(store, SESSION, { txId: TX, docs: [doc('events.json', 0, [rec('e1')])] });
  assert.equal(await store.readDoc(OTHER, 'events.json'), null);
  const otherVersions = await getVersionsLogic(store, { accountId: OTHER });
  assert.deepEqual(otherVersions.docs['events.json'], { version: 0, updatedAt: null });
});

test('payload 不透明：未知字段与嵌套结构原样存取', async () => {
  const store = new MemoryStore();
  const payload = {
    items: [{ id: 'x1', deleted: false, 未知字段: { 深层: ['a', 1, null, true] } }],
    附注: '云函数不得解析或改写 payload',
  };
  await commitTxLogic(store, SESSION, { txId: TX, docs: [{ name: 'tasks.json', baseVersion: 0, payload }] });

  const saved = await store.readDoc(ACC, 'tasks.json');
  assert.deepEqual(saved.payload, payload);
});

test('会话缺失 → UNAUTHENTICATED', async () => {
  const store = new MemoryStore();
  await assert.rejects(
    () => commitTxLogic(store, null, { txId: TX, docs: [doc('projects.json', 0, [])] }),
    (err) => err.code === Code.UNAUTHENTICATED,
  );
});

test('入参校验：全部非法输入 → INVALID', async () => {
  const store = new MemoryStore();
  const bad = [
    { txId: 'short', docs: [doc('projects.json', 0, [])] },
    { txId: TX, docs: [] },
    { txId: TX, docs: 'not-array' },
    { txId: TX, docs: [doc('unknown.json', 0, [])] },
    { txId: TX, docs: [doc('projects.json', 0, []), doc('projects.json', 0, [])] },
    { txId: TX, docs: [{ name: 'projects.json', baseVersion: -1, payload: { items: [] } }] },
    { txId: TX, docs: [{ name: 'projects.json', baseVersion: 1.5, payload: { items: [] } }] },
    { txId: TX, docs: [{ name: 'projects.json', baseVersion: 0 }] },
    { txId: TX, docs: [{ name: 'projects.json', baseVersion: 0, payload: {} }] },
    { txId: TX, docs: [doc('projects.json', 0, []), doc('tasks.json', 0, []), doc('events.json', 0, []), doc('inspirations.json', 0, []), doc('projects.json', 0, [])] },
  ];

  for (const input of bad) {
    await assert.rejects(
      () => commitTxLogic(store, SESSION, input),
      (err) => err.code === Code.INVALID,
      `应判为 INVALID：${JSON.stringify(input).slice(0, 80)}`,
    );
  }
});

test('超过单文档上限 → INVALID（并给出字节数）', async () => {
  const store = new MemoryStore();
  const big = 'x'.repeat(LIMITS.MAX_PAYLOAD_BYTES + 16);
  await assert.rejects(
    () => commitTxLogic(store, SESSION, { txId: TX, docs: [doc('tasks.json', 0, [big])] }),
    (err) => err.code === Code.INVALID && typeof err.details.bytes === 'number',
  );
});

test('getVersions：未创建的文档返回 version 0 / updatedAt null', async () => {
  const store = new MemoryStore();
  const out = await getVersionsLogic(store, SESSION);
  assert.deepEqual(Object.keys(out.docs).sort(), [
    'events.json',
    'inspirations.json',
    'projects.json',
    'tasks.json',
  ]);
  assert.deepEqual(out.docs['projects.json'], { version: 0, updatedAt: null });
});

test('getDoc：未创建的文档返回空 items（不是错误）', async () => {
  const store = new MemoryStore();
  const out = await getDocLogic(store, SESSION, { name: 'inspirations.json' });
  assert.equal(out.version, 0);
  assert.equal(out.updatedAt, null);
  assert.deepEqual(out.payload, { items: [] });
});

test('getDoc：未知文档名 → INVALID', async () => {
  const store = new MemoryStore();
  await assert.rejects(
    () => getDocLogic(store, SESSION, { name: '../secrets.json' }),
    (err) => err.code === Code.INVALID,
  );
});
