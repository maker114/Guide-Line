'use strict';

/**
 * 身份逻辑（《同步与云函数契约》§4.4 ~ §4.6）。
 *
 * 设计要点：
 *   · 单人项目**不做账号体系**，但必须有一个**可迁移的身份根** → 恢复码；
 *   · 恢复码**只存 sha256(salt + code)**，明文永不落库、永不入日志；
 *   · 配对码 6 位、TTL 5 分钟、**单次使用**（takeOne 原子取走）；
 *   · 失败计数 + 冷却，且**不区分「码错误」与「码过期」**（防枚举）；
 *   · 签发登录票委托给注入的 issueTicket（CloudBase 自定义登录），便于离线测试。
 *
 * 集契约：`store.readOne/insertOne/updateOne/deleteOne/takeOne`
 */

const crypto = require('crypto');
const { AppError, Code } = require('./errors');

const RECOVERY_CODE_LENGTH = 24;
/** 恢复码字母表：剔除易混字符 0 / O / 1 / I */
const RECOVERY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

const PAIRING_CODE_LENGTH = 6;
const PAIRING_CODE_TTL_MS = 5 * 60 * 1000;
const PAIRING_CODE_INSERT_RETRY = 5;

const FAIL_LIMIT = 5;
const COOLDOWN_MS = 10 * 60 * 1000;
const TICKET_TTL_MS = 5 * 60 * 1000;

const DEVICE_NAME_MAX = 64;

const COLLECTIONS = Object.freeze({
  accounts: 'accounts',
  devices: 'devices',
  pairingCodes: 'pairing_codes',
  cooldowns: 'cooldowns',
});

// ---------- 工具 ----------

function assertSession(session) {
  if (!session || typeof session.accountId !== 'string' || session.accountId.length === 0) {
    throw new AppError(Code.UNAUTHENTICATED, '会话无效或已过期');
  }
}

function requireId(value, field) {
  const s = String(value == null ? '' : value).trim();
  if (s.length === 0 || s.length > 128) throw new AppError(Code.INVALID, `${field} 缺失或非法`);
  return s;
}

function normalizeDeviceName(value) {
  const s = String(value == null ? '' : value).trim();
  if (s.length === 0) return '未命名设备';
  return s.slice(0, DEVICE_NAME_MAX);
}

/** 归一化恢复码：大写 + 去掉分隔符与空格 */
function normalizeRecoveryCode(value) {
  return String(value == null ? '' : value)
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}

function hashRecoveryCode(code, salt) {
  return crypto.createHash('sha256').update(`${salt}:${normalizeRecoveryCode(code)}`, 'utf8').digest('hex');
}

function safeEqualHex(a, b) {
  const ba = Buffer.from(String(a), 'hex');
  const bb = Buffer.from(String(b), 'hex');
  if (ba.length === 0 || ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

/** 由随机字节生成 UUID v4 字符串（服务端生成 accountId，避免客户端抢注） */
function uuidV4(bytes) {
  const b = Buffer.from(bytes);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

function generatePairingCode(random) {
  const n = random(4).readUInt32BE(0) % 1000000;
  return String(n).padStart(PAIRING_CODE_LENGTH, '0');
}

function deviceKey(accountId, deviceId) {
  return `${accountId}:${deviceId}`;
}

function cooldownKey(kind, subject) {
  return `${kind}:${subject}`;
}

async function assertNotCoolingDown(store, key, now) {
  const rec = await store.readOne(COLLECTIONS.cooldowns, key);
  if (rec && rec.until > now) {
    const seconds = Math.ceil((rec.until - now) / 1000);
    throw new AppError(Code.RATE_LIMITED, `尝试过于频繁，请 ${seconds} 秒后再试`, { retryAfterSeconds: seconds });
  }
}

async function recordFailure(store, key, now) {
  const rec = await store.readOne(COLLECTIONS.cooldowns, key);
  const count = (rec && rec.count ? rec.count : 0) + 1;
  const until = count >= FAIL_LIMIT ? now + COOLDOWN_MS : 0;
  const next = { _id: key, count, until, updatedAt: now };
  if (rec) await store.updateOne(COLLECTIONS.cooldowns, key, next);
  else await store.insertOne(COLLECTIONS.cooldowns, next);
  return { count, until };
}

async function clearFailures(store, key) {
  await store.deleteOne(COLLECTIONS.cooldowns, key);
}

async function upsertDevice(store, accountId, deviceId, name, now) {
  const id = deviceKey(accountId, deviceId);
  const existing = await store.readOne(COLLECTIONS.devices, id);
  if (existing) {
    await store.updateOne(COLLECTIONS.devices, id, { name, lastSeenAt: now, revoked: false });
    return;
  }
  await store.insertOne(COLLECTIONS.devices, {
    _id: id,
    accountId,
    deviceId,
    name,
    lastSeenAt: now,
    revoked: false,
  });
}

// ---------- 逻辑 ----------

/**
 * registerAccount —— 首端初始化。
 * 客户端生成**恢复码**，服务端生成 accountId 并建档；返回登录票。
 */
async function registerAccountLogic(store, input, deps) {
  const code = normalizeRecoveryCode(input && input.recoveryCode);
  if (code.length !== RECOVERY_CODE_LENGTH) {
    throw new AppError(Code.INVALID, `恢复码必须是 ${RECOVERY_CODE_LENGTH} 位字符`);
  }
  const deviceId = requireId(input && input.deviceId, 'deviceId');
  const deviceName = normalizeDeviceName(input && input.deviceName);
  const now = deps.now();

  const accountId = uuidV4(deps.random(16));
  const salt = deps.random(16).toString('hex');

  await store.insertOne(COLLECTIONS.accounts, {
    _id: accountId,
    recoveryHash: hashRecoveryCode(code, salt),
    recoverySalt: salt,
    activePairingCode: null,
    activePairingExpiresAt: null,
    createdAt: now,
    lastSeenAt: now,
  });
  await upsertDevice(store, accountId, deviceId, deviceName, now);

  const ticket = await deps.issueTicket({ accountId, deviceId });
  return { accountId, deviceId, ticket, ticketExpiresAt: now + TICKET_TTL_MS };
}

/** createPairingCode —— 首端「添加设备」：生成 6 位一次性配对码 */
async function createPairingCodeLogic(store, session, _input, deps) {
  assertSession(session);
  const now = deps.now();

  const account = await store.readOne(COLLECTIONS.accounts, session.accountId);
  if (!account) throw new AppError(Code.UNAUTHENTICATED, '账号不存在');

  let code = null;
  for (let i = 0; i < PAIRING_CODE_INSERT_RETRY && code === null; i += 1) {
    const candidate = generatePairingCode(deps.random);
    try {
      await store.insertOne(COLLECTIONS.pairingCodes, {
        _id: candidate,
        accountId: session.accountId,
        expiresAt: now + PAIRING_CODE_TTL_MS,
        createdAt: now,
      });
      code = candidate;
    } catch (err) {
      if (err.code !== 'DUPLICATE') throw err; // 6 位码撞车则重试
    }
  }
  if (code === null) throw new AppError(Code.INTERNAL, '配对码生成失败，请重试');

  // 同一账号只保留最新一个有效码
  if (account.activePairingCode && account.activePairingCode !== code) {
    await store.deleteOne(COLLECTIONS.pairingCodes, account.activePairingCode);
  }
  await store.updateOne(COLLECTIONS.accounts, session.accountId, {
    activePairingCode: code,
    activePairingExpiresAt: now + PAIRING_CODE_TTL_MS,
  });

  return { code, expiresAt: now + PAIRING_CODE_TTL_MS };
}

/** pair —— 次端用配对码换取同一 accountId 的登录票（无需会话） */
async function pairLogic(store, input, deps) {
  const now = deps.now();
  const deviceId = requireId(input && input.deviceId, 'deviceId');
  const deviceName = normalizeDeviceName(input && input.deviceName);
  const key = cooldownKey('pair', deviceId);
  await assertNotCoolingDown(store, key, now);

  const raw = String((input && input.code) == null ? '' : input.code).replace(/[^0-9]/g, '');
  const rec = raw.length === PAIRING_CODE_LENGTH ? await store.takeOne(COLLECTIONS.pairingCodes, raw) : null;
  const valid = rec !== null && rec.expiresAt > now;

  if (!valid) {
    await recordFailure(store, key, now);
    // 不区分「码错误」与「码过期」，避免枚举
    throw new AppError(Code.UNAUTHENTICATED, '配对码无效或已过期');
  }

  await clearFailures(store, key);
  await upsertDevice(store, rec.accountId, deviceId, deviceName, now);
  await store.updateOne(COLLECTIONS.accounts, rec.accountId, {
    activePairingCode: null,
    activePairingExpiresAt: null,
    lastSeenAt: now,
  });

  const ticket = await deps.issueTicket({ accountId: rec.accountId, deviceId });
  return { accountId: rec.accountId, ticket, ticketExpiresAt: now + TICKET_TTL_MS };
}

/** issueTicket —— 用恢复码换登录票（换机 / 重装） */
async function issueTicketLogic(store, input, deps) {
  const now = deps.now();
  const accountId = String((input && input.accountId) == null ? '' : input.accountId).trim();
  if (accountId.length === 0) throw new AppError(Code.INVALID, 'accountId 缺失');
  const deviceId = requireId(input && input.deviceId, 'deviceId');
  const deviceName = normalizeDeviceName(input && input.deviceName);

  const key = cooldownKey('issue', accountId);
  await assertNotCoolingDown(store, key, now);

  const account = await store.readOne(COLLECTIONS.accounts, accountId);
  const salt = account ? account.recoverySalt : 'absent-account-salt';
  const expected = account
    ? account.recoveryHash
    : hashRecoveryCode('X'.repeat(RECOVERY_CODE_LENGTH), salt); // 账号不存在也走同样的计算量
  const provided = hashRecoveryCode(input && input.recoveryCode, salt);

  if (!account || !safeEqualHex(expected, provided)) {
    await recordFailure(store, key, now);
    throw new AppError(Code.UNAUTHENTICATED, '恢复码不正确');
  }

  await clearFailures(store, key);
  await upsertDevice(store, accountId, deviceId, deviceName, now);
  await store.updateOne(COLLECTIONS.accounts, accountId, { lastSeenAt: now });

  const ticket = await deps.issueTicket({ accountId, deviceId });
  return { accountId, ticket, ticketExpiresAt: now + TICKET_TTL_MS };
}

/** rotateRecoveryCode —— 重新生成恢复码（旧码立即失效；默认关闭的增强入口） */
async function rotateRecoveryCodeLogic(store, session, input, deps) {
  assertSession(session);
  const code = normalizeRecoveryCode(input && input.newRecoveryCode);
  if (code.length !== RECOVERY_CODE_LENGTH) {
    throw new AppError(Code.INVALID, `恢复码必须是 ${RECOVERY_CODE_LENGTH} 位字符`);
  }
  const account = await store.readOne(COLLECTIONS.accounts, session.accountId);
  if (!account) throw new AppError(Code.UNAUTHENTICATED, '账号不存在');

  const salt = deps.random(16).toString('hex');
  await store.updateOne(COLLECTIONS.accounts, session.accountId, {
    recoveryHash: hashRecoveryCode(code, salt),
    recoverySalt: salt,
    rotatedAt: deps.now(),
  });
  return { rotatedAt: deps.now() };
}

module.exports = {
  RECOVERY_CODE_LENGTH,
  RECOVERY_ALPHABET,
  PAIRING_CODE_LENGTH,
  PAIRING_CODE_TTL_MS,
  FAIL_LIMIT,
  COOLDOWN_MS,
  TICKET_TTL_MS,
  COLLECTIONS,
  normalizeRecoveryCode,
  hashRecoveryCode,
  safeEqualHex,
  uuidV4,
  generatePairingCode,
  registerAccountLogic,
  createPairingCodeLogic,
  pairLogic,
  issueTicketLogic,
  rotateRecoveryCodeLogic,
};
