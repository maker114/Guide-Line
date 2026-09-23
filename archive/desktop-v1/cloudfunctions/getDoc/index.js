'use strict';

/**
 * getDoc —— 读取整包 payload（《同步与云函数契约》§4.3）。
 * payload 原样返回，云函数不做任何解析。
 */

const { bootstrap } = require('../common/runtime');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { getDocLogic } = require('../common/logic');

const rt = bootstrap();

exports.main = createHandler({
  getStore: async () => rt.store,
  resolveSession: () => resolveSessionFromRuntime(rt.app),
  logic: getDocLogic,
});
