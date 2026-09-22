'use strict';

/**
 * rotateRecoveryCode —— 重新生成恢复码，旧码立即失效（《同步与云函数契约》§4.6 末）。
 * 需要会话；部署后建议默认**不对外暴露**（仅供自己在控制台或本机调用）。
 */

const { bootstrap } = require('../common/runtime');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { rotateRecoveryCodeLogic } = require('../common/identity');

const rt = bootstrap();

exports.main = createHandler({
  getStore: async () => rt.store,
  resolveSession: () => resolveSessionFromRuntime(rt.app),
  logic: rotateRecoveryCodeLogic,
  deps: rt.deps,
});
