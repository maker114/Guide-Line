'use strict';

/**
 * getVersions —— 只读元数据探测（《同步与云函数契约》§4.2）。
 * 轮询（Windows 端 5 分钟）**只能**调用本函数，避免每次下载整包 payload。
 */

const cloudbase = require('@cloudbase/node-sdk');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { getVersionsLogic } = require('../common/logic');
const { CloudBaseStore } = require('../common/stores');

const app = cloudbase.init({ env: cloudbase.SYMBOL_CURRENT_ENV });
const store = new CloudBaseStore(app.database());

exports.main = createHandler({
  getStore: async () => store,
  resolveSession: () => resolveSessionFromRuntime(app),
  logic: getVersionsLogic,
});
