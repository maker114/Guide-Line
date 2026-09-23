'use strict';

/**
 * 身份逻辑测试（不需要云环境，只需要 node:crypto）。
 *
 *   node test/run.js
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const { MemoryStore } = require('../common/stores');
const {
  COLLECTIONS,
  RECOVERY_CODE_LENGTH,
  PAIRING_CODE_TTL_MS,
  COOLDOWN_MS,
  normalizeRecoveryCode,
  hashRecoveryCode,
  uuidV4,
  registerAccountLogic,
  createPairingCodeLogic,
  pairLogic,
  issueTicketLogic,
  rotateRecoveryCodeLogic,
} = require('../common/identity');
const { Code } = require('../common/errors');

const DEVICE_A = 'device-desktop-0001';
const DEVICE_B = 'device-android-0002';
const RECOVERY = 'ABCDEFGHJKLMNPQRSTUVWX23'; // 24 位，字母表内
const RECOVERY_2 = 'ZYXWVUTSRQPNMLKJHGFEDC32';

/** 可控时钟 + 可预测随机 + 假登录票签发器 */
function makeDeps(startAt) {
  let t = startAt || 1800000000000;
  let seed = 0;
  const issued = [];
  return {
    now: () => t,
    random: (n) => {
      seed += 1;
      const b = Buffer.alloc(n);
      b.writeUInt32BE(seed % 0xffffffff, 0);
      for (let i = 4; i < n; i += 1) b[i] = (seed * 7 + i) % 251;
      return b;
    },
    issueTicket: async ({ accountId, deviceId }) => {
      const ticket = `ticket-${issued.length + 1}`;
      issued.push({ accountId, deviceId, ticket });
      return ticket;
    },
    advance: (ms) => {
      t += ms;
    },
    issued,
  };
}

async function seedAccount(store, deps, recoveryCode) {
  return registerAccountLogic(
    store,
    { recoveryCode: recoveryCode || RECOVERY, deviceId: DEVICE_A, deviceName: 'Windows PC' },
    deps,
  );
}

test('registerAccount：返回 accountId 与登录票，且明文恢复码绝不落库', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();

  const out = await registerAccountLogic(
    store,
    { recoveryCode: RECOVERY, deviceId: DEVICE_A, deviceName: 'Windows PC' },
    deps,
  );

  assert.match(out.accountId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(out.ticket, 'ticket-1');
  assert.equal(out.deviceId, DEVICE_A);

  const account = await store.readOne(COLLECTIONS.accounts, out.accountId);
  assert.equal(account.recoveryHash.length, 64);
  assert.notEqual(account.recoveryHash, RECOVERY);
  assert.equal(
    JSON.stringify(account).includes(RECOVERY),
    false,
    '账号记录里绝不能出现明文恢复码',
  );

  const device = await store.readOne(COLLECTIONS.devices, `${out.accountId}:${DEVICE_A}`);
  assert.equal(device.name, 'Windows PC');
  assert.equal(device.revoked, false);
});

test('registerAccount：恢复码长度非法 → INVALID', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  await assert.rejects(
    () => registerAccountLogic(store, { recoveryCode: 'TOOSHORT', deviceId: DEVICE_A }, deps),
    (err) => err.code === Code.INVALID,
  );
});

test('registerAccount：带分隔符与小写的恢复码被归一化后可用', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const pretty = 'abcd-efgh-jklm-npqr-stuv-wx-23';
  const out = await registerAccountLogic(store, { recoveryCode: pretty, deviceId: DEVICE_A }, deps);

  const normalized = normalizeRecoveryCode(pretty);
  assert.equal(normalized.length, RECOVERY_CODE_LENGTH);

  const account = await store.readOne(COLLECTIONS.accounts, out.accountId);
  assert.equal(account.recoveryHash, hashRecoveryCode(normalized, account.recoverySalt));
});

test('createPairingCode：无会话 → UNAUTHENTICATED', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  await assert.rejects(
    () => createPairingCodeLogic(store, null, {}, deps),
    (err) => err.code === Code.UNAUTHENTICATED,
  );
});

test('createPairingCode：生成 6 位码 + 5 分钟 TTL，且新码使旧码立即失效', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);
  const session = { accountId: acc.accountId };

  const first = await createPairingCodeLogic(store, session, {}, deps);
  assert.match(first.code, /^[0-9]{6}$/);
  assert.equal(first.expiresAt - deps.now(), PAIRING_CODE_TTL_MS);

  const second = await createPairingCodeLogic(store, session, {}, deps);
  assert.notEqual(second.code, first.code);
  assert.equal(await store.readOne(COLLECTIONS.pairingCodes, first.code), null, '旧码必须被清除');

  await assert.rejects(
    () => pairLogic(store, { code: first.code, deviceId: DEVICE_B }, deps),
    (err) => err.code === Code.UNAUTHENTICATED,
  );
});

test('pair：正确码换到同一 accountId 的票，且码只能使用一次', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);
  const { code } = await createPairingCodeLogic(store, { accountId: acc.accountId }, {}, deps);

  const paired = await pairLogic(store, { code, deviceId: DEVICE_B, deviceName: 'Android' }, deps);
  assert.equal(paired.accountId, acc.accountId, '两端必须落在同一个 accountId');
  assert.equal(paired.ticket, 'ticket-2');

  const device = await store.readOne(COLLECTIONS.devices, `${acc.accountId}:${DEVICE_B}`);
  assert.equal(device.name, 'Android');

  // 单次使用
  await assert.rejects(
    () => pairLogic(store, { code, deviceId: 'device-third-0003' }, deps),
    (err) => err.code === Code.UNAUTHENTICATED,
  );
});

test('pair：过期码（>5 分钟）→ UNAUTHENTICATED', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);
  const { code } = await createPairingCodeLogic(store, { accountId: acc.accountId }, {}, deps);

  deps.advance(PAIRING_CODE_TTL_MS + 1);

  await assert.rejects(
    () => pairLogic(store, { code, deviceId: DEVICE_B }, deps),
    (err) => err.code === Code.UNAUTHENTICATED,
  );
});

test('pair：失败 5 次后进入 10 分钟冷却，冷却期内连正确码也被拒', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);

  for (let i = 0; i < 5; i += 1) {
    await assert.rejects(
      () => pairLogic(store, { code: '999999', deviceId: DEVICE_B }, deps),
      (err) => err.code === Code.UNAUTHENTICATED,
      `第 ${i + 1} 次失败应为 UNAUTHENTICATED`,
    );
  }

  const { code } = await createPairingCodeLogic(store, { accountId: acc.accountId }, {}, deps);
  await assert.rejects(
    () => pairLogic(store, { code, deviceId: DEVICE_B }, deps),
    (err) => err.code === Code.RATE_LIMITED,
  );

  // 冷却期（10 分钟）长于配对码有效期（5 分钟）→ 解除锁定后必须重新生成配对码
  deps.advance(COOLDOWN_MS + 1);
  const fresh = await createPairingCodeLogic(store, { accountId: acc.accountId }, {}, deps);
  const paired = await pairLogic(store, { code: fresh.code, deviceId: DEVICE_B }, deps);
  assert.equal(paired.accountId, acc.accountId);
});

test('issueTicket：正确恢复码换票；错误恢复码 → UNAUTHENTICATED', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);

  const okOut = await issueTicketLogic(
    store,
    { accountId: acc.accountId, recoveryCode: RECOVERY, deviceId: 'device-new-0009' },
    deps,
  );
  assert.equal(okOut.accountId, acc.accountId);
  assert.match(okOut.ticket, /^ticket-/);

  await assert.rejects(
    () => issueTicketLogic(store, { accountId: acc.accountId, recoveryCode: RECOVERY_2, deviceId: 'device-x' }, deps),
    (err) => err.code === Code.UNAUTHENTICATED,
  );
});

test('issueTicket：账号不存在与恢复码错误返回完全相同的错误（不泄漏账号是否存在）', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);

  let absent;
  let wrong;
  try {
    await issueTicketLogic(store, { accountId: '00000000-0000-4000-8000-000000000000', recoveryCode: RECOVERY, deviceId: 'd1' }, deps);
    throw new Error('应当失败');
  } catch (err) {
    absent = err;
  }
  try {
    await issueTicketLogic(store, { accountId: acc.accountId, recoveryCode: RECOVERY_2, deviceId: 'd2' }, deps);
    throw new Error('应当失败');
  } catch (err) {
    wrong = err;
  }

  assert.equal(absent.code, wrong.code);
  assert.equal(absent.message, wrong.message);
});

test('issueTicket：失败 5 次后冷却，冷却结束可再次成功', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);

  for (let i = 0; i < 5; i += 1) {
    await assert.rejects(
      () => issueTicketLogic(store, { accountId: acc.accountId, recoveryCode: RECOVERY_2, deviceId: 'd1' }, deps),
      (err) => err.code === Code.UNAUTHENTICATED,
    );
  }
  await assert.rejects(
    () => issueTicketLogic(store, { accountId: acc.accountId, recoveryCode: RECOVERY, deviceId: 'd1' }, deps),
    (err) => err.code === Code.RATE_LIMITED,
  );

  deps.advance(COOLDOWN_MS + 1);
  const out = await issueTicketLogic(
    store,
    { accountId: acc.accountId, recoveryCode: RECOVERY, deviceId: 'd1' },
    deps,
  );
  assert.equal(out.accountId, acc.accountId);
});

test('rotateRecoveryCode：旧码立即失效，新码可用', async () => {
  const store = new MemoryStore();
  const deps = makeDeps();
  const acc = await seedAccount(store, deps);

  await rotateRecoveryCodeLogic(store, { accountId: acc.accountId }, { newRecoveryCode: RECOVERY_2 }, deps);

  await assert.rejects(
    () => issueTicketLogic(store, { accountId: acc.accountId, recoveryCode: RECOVERY, deviceId: 'd1' }, deps),
    (err) => err.code === Code.UNAUTHENTICATED,
  );

  const out = await issueTicketLogic(
    store,
    { accountId: acc.accountId, recoveryCode: RECOVERY_2, deviceId: 'd1' },
    deps,
  );
  assert.equal(out.accountId, acc.accountId);
});

test('工具函数：uuidV4 形态、哈希加盐后不同、归一化去分隔符', () => {
  assert.equal(RECOVERY.length, RECOVERY_CODE_LENGTH, '测试夹具本身必须是 24 位');
  assert.equal(RECOVERY_2.length, RECOVERY_CODE_LENGTH, '测试夹具本身必须是 24 位');
  assert.match(uuidV4(Buffer.alloc(16, 7)), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.notEqual(hashRecoveryCode(RECOVERY, 'salt-a'), hashRecoveryCode(RECOVERY, 'salt-b'));
  assert.equal(hashRecoveryCode(RECOVERY, 'salt-a'), hashRecoveryCode(RECOVERY.toLowerCase(), 'salt-a'));
  assert.equal(normalizeRecoveryCode(' ab-cd ef '), 'ABCDEF');
});
