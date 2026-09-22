'use strict';

/**
 * 云函数外壳：会话解析 + 统一信封（ok / 错误码）。
 *
 * 身份设计（《同步与云函数契约》§9 / 设计文档 7.2）：
 *   签发自定义登录票时把 uid 设为 accountId，
 *   于是云函数里的终端用户 uid **就是** accountId，无需任何入参传递。
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

/**
 * @param {object} deps
 * @param {() => Promise<object>} deps.getStore    返回存储实现
 * @param {() => Promise<{accountId:string}>} deps.resolveSession
 * @param {(store:object, session:object, input:object) => Promise<object>} deps.logic
 */
function createHandler(deps) {
  const { getStore, resolveSession, logic } = deps;
  return async function handler(event) {
    try {
      const store = await getStore();
      const session = await resolveSession();
      const result = await logic(store, session, event || {});
      return ok(result);
    } catch (err) {
      if (err instanceof AppError) return fail(err);
      // 只记错误与调用上下文，绝不记录 payload（《同步与云函数契约》§9）
      console.error('[INTERNAL]', err && err.stack ? err.stack : String(err));
      return fail(new AppError(Code.INTERNAL, '服务内部错误'));
    }
  };
}

module.exports = { createHandler, resolveSessionFromRuntime };
