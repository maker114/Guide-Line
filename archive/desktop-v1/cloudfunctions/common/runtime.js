'use strict';

/**
 * 云函数运行时装配：把 CloudBase SDK 的初始化与依赖注入集中在一处，
 * 让各个 index.js 只剩「接线」，也让 [待联调确认] 的 SDK 细节只有一个落点。
 */

const crypto = require('crypto');
const cloudbase = require('@cloudbase/node-sdk');
const { CloudBaseStore } = require('./stores');
const { makeTicketIssuer } = require('./ticket');

function bootstrap() {
  // [待联调确认] SYMBOL_CURRENT_ENV 用于「当前环境」初始化
  const app = cloudbase.init({ env: cloudbase.SYMBOL_CURRENT_ENV });
  const store = new CloudBaseStore(app.database());
  const deps = {
    now: () => Date.now(),
    random: (n) => crypto.randomBytes(n),
    issueTicket: makeTicketIssuer(app),
  };
  return { app, store, deps };
}

module.exports = { bootstrap };
