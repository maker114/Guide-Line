'use strict';

/**
 * createPairingCode —— 首端「添加设备」，生成 6 位一次性配对码（《同步与云函数契约》§4.5）。
 * 需要会话（只有已登录的首端才能给别人发配对码）。
 */

const { bootstrap } = require('../common/runtime');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { createPairingCodeLogic } = require('../common/identity');

const rt = bootstrap();

exports.main = createHandler({
  getStore: async () => rt.store,
  resolveSession: () => resolveSessionFromRuntime(rt.app),
  logic: createPairingCodeLogic,
  deps: rt.deps,
});
