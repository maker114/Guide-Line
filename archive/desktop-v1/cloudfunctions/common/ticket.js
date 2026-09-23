'use strict';

/**
 * 登录票签发（CloudBase **自定义登录**）。
 *
 * ⚠️ [待联调确认] 这是全项目唯一无法离线验证的外部契约，必须与 CloudBase 文档核对三件事：
 *   1. 自定义登录票的创建 API 名称与入参（本文件按 `auth().createTicket(uid, opts)` 写）；
 *   2. `uid` 必须等于我们自己的 accountId —— 这样云函数里 getEndUserInfo().uid 就是 accountId，
 *      不需要任何入参传递，也不可能被伪造；
 *   3. ticket 的有效期与是否单次使用（我们按「≤5 分钟、单次」的目标设计）。
 *
 * 在未核对之前，本函数会**显式抛错**而不是静默返回一个假票 —— 宁可联调时报错，也不要让设备拿到无效会话。
 */

const { AppError, Code } = require('./errors');

const TICKET_OPTIONS = Object.freeze({
  // 自定义登录票的有效期上限（秒）；实际有效期以 CloudBase 平台为准
  expiresInSeconds: 5 * 60,
});

function makeTicketIssuer(app) {
  return async function issueTicket({ accountId, deviceId }) {
    const auth = app.auth();
    if (!auth || typeof auth.createTicket !== 'function') {
      throw new AppError(
        Code.INTERNAL,
        '登录票签发未配置：请按 README「待确认清单」核对 CloudBase 自定义登录 API',
      );
    }
    const ticket = await auth.createTicket(accountId, {
      ...TICKET_OPTIONS,
      // 便于审计：把设备号带进自定义声明（若平台不支持该参数则忽略）
      customClaims: { deviceId },
    });
    if (!ticket) throw new AppError(Code.INTERNAL, '登录票签发返回空值');
    return ticket;
  };
}

module.exports = { makeTicketIssuer, TICKET_OPTIONS };
