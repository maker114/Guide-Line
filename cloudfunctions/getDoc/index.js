'use strict';

/**
 * getDoc —— 读取整包 payload（《同步与云函数契约》§4.3）。
 * payload 原样返回，云函数不做任何解析。
 */

const cloudbase = require('@cloudbase/node-sdk');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { getDocLogic } = require('../common/logic');
const { CloudBaseStore } = require('../common/stores');

const app = cloudbase.init({ env: cloudbase.SYMBOL_CURRENT_ENV });
const store = new CloudBaseStore(app.database());

exports.main = createHandler({
  getStore: async () => store,
  resolveSession: () => resolveSessionFromRuntime(app),
  logic: getDocLogic,
});
