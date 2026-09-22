'use strict';

/**
 * getVersions —— 只读元数据探测（《同步与云函数契约》§4.2）。
 * 轮询（Windows 端 5 分钟）**只能**调用本函数，避免每次下载整包 payload。
 */

const { bootstrap } = require('../common/runtime');
const { createHandler, resolveSessionFromRuntime } = require('../common/handler');
const { getVersionsLogic } = require('../common/logic');

const rt = bootstrap();

exports.main = createHandler({
  getStore: async () => rt.store,
  resolveSession: () => resolveSessionFromRuntime(rt.app),
  logic: getVersionsLogic,
});
