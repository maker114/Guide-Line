'use strict';

/**
 * issueTicket —— 用恢复码换登录票（换机 / 重装，见《同步与云函数契约》§4.6）。
 * 无需会话：这正是「如何重新获得会话」的入口。
 */

const { bootstrap } = require('../common/runtime');
const { createPublicHandler } = require('../common/handler');
const { issueTicketLogic } = require('../common/identity');

const rt = bootstrap();

exports.main = createPublicHandler({
  getStore: async () => rt.store,
  logic: issueTicketLogic,
  deps: rt.deps,
});
