'use strict';

/**
 * commitTx —— 唯一写入口（《同步与云函数契约》§4.1）。
 * 单文档变更也走这里，保证全系统只有一条写入路径。
 */

const { bootstrap } = require('../common/runtime');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { commitTxLogic } = require('../common/logic');

const rt = bootstrap();

exports.main = createHandler({
  getStore: async () => rt.store,
  resolveSession: () => resolveSessionFromRuntime(rt.app),
  logic: commitTxLogic,
});
