'use strict';

/**
 * commitTx —— 唯一写入口（《同步与云函数契约》§4.1）。
 * 单文档变更也走这里，保证全系统只有一条写入路径。
 */

const cloudbase = require('@cloudbase/node-sdk');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { commitTxLogic } = require('../common/logic');
const { CloudBaseStore } = require('../common/stores');

// [待联调确认] SYMBOL_CURRENT_ENV 用于「当前环境」初始化
const app = cloudbase.init({ env: cloudbase.SYMBOL_CURRENT_ENV });
const store = new CloudBaseStore(app.database());

exports.main = createHandler({
  getStore: async () => store,
  resolveSession: () => resolveSessionFromRuntime(app),
  logic: commitTxLogic,
});
