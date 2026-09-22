'use strict';

/**
 * 云函数外壳：会话解析 + 统一信封（ok / 错误码）。
 *
 * 身份设计（《同步与云函数契约》§9 / 设计文档 7.2）：
 *   签发自定义登录票时把 uid 设为 accountId，
 *   于是云函数里的终端用户 uid **就是** accountId，无需任何入参传递。
 *
 * 两类入口：
 *   createHandler        —— 需要会话（同步三件套、createPairingCode、rotateRecoveryCode）
 *   createPublicHandler  —— 无需会话（registerAccount / pair / issueTicket 在拿到会话之前调用）
 */

const { AppError, Code, ok, fail } = require('./errors');

/**
 * 从云开发运行时解析会话。
 * [待联调确认] getEndUserInfo 的确切调用形态与返回结构。
 */
async function resolveSessionFromRuntime(app) {
  const info = await app.auth().getEndUserInfo();
  const uid = info && info.userInfo ? info.userInfo.uid : undefined;
  if (!uid) throw new AppError(Code.UNAUTHENTICATED, '未登录或会话已失效');
  return { accountId: uid };
}

async function run(deps, event, withSession) {
  try {
    const store = await deps.getStore();
    const session = withSession ? await deps.resolveSession() : null;
    const result = await deps.logic(store, session, event || {}, deps.deps);
    return ok(result);
  } catch (err) {
    if (err instanceof AppError) return fail(err);
    // 只记错误与调用上下文，绝不记录 payload 或恢复码（《同步与云函数契约》§9）
    console.error('[INTERNAL]', err && err.stack ? err.stack : String(err));
    return fail(new AppError(Code.INTERNAL, '服务内部错误'));
  }
}

/** 需要会话的云函数 */
function createHandler(deps) {
  return async function handler(event) {
    return run(deps, event, true);
  };
}

/** 无需会话的云函数（会话建立之前调用） */
function createPublicHandler(deps) {
  return async function handler(event) {
    return run(deps, event, false);
  };
}

module.exports = { createHandler, createPublicHandler, resolveSessionFromRuntime };
