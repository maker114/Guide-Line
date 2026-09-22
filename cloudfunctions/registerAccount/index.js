'use strict';

/**
 * registerAccount —— 首端初始化（《同步与云函数契约》§4.4）。
 * 无需会话：客户端此时还没有登录票。
 * 客户端生成恢复码，服务端生成 accountId 并只存 sha256(salt + code)。
 */

const { bootstrap } = require('../common/runtime');
const { createPublicHandler } = require('../common/handler');
const { registerAccountLogic } = require('../common/identity');

const rt = bootstrap();

exports.main = createPublicHandler({
  getStore: async () => rt.store,
  logic: registerAccountLogic,
  deps: rt.deps,
});
