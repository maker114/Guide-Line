'use strict';

/**
 * pair —— 次端用配对码换取同一 accountId 的登录票（《同步与云函数契约》§4.5）。
 * 无需会话：次端此时还没有登录票。
 */

const { bootstrap } = require('../common/runtime');
const { createPublicHandler } = require('../common/handler');
const { pairLogic } = require('../common/identity');

const rt = bootstrap();

exports.main = createPublicHandler({
  getStore: async () => rt.store,
  logic: pairLogic,
  deps: rt.deps,
});
