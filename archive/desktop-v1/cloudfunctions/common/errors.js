'use strict';

/**
 * 错误码与限额（与《同步与云函数契约》§8 一一对应）。
 * 所有云函数统一返回 { ok:false, code, message }，HTTP 层仍是 200，
 * 避免 SDK 抛网络异常掩盖业务错误。
 */

const Code = Object.freeze({
  UNAUTHENTICATED: 'UNAUTHENTICATED',
  FORBIDDEN: 'FORBIDDEN',
  CONFLICT: 'CONFLICT',
  NOT_FOUND: 'NOT_FOUND',
  RATE_LIMITED: 'RATE_LIMITED',
  INVALID: 'INVALID',
  INTERNAL: 'INTERNAL',
});

const LIMITS = Object.freeze({
  /** 单文档 payload 上限（《数据契约》§2 / L2 升级触发条件） */
  MAX_PAYLOAD_BYTES: 5 * 1024 * 1024,
  /** 一次事务最多几份文档（本系统固定 4 份） */
  MAX_DOCS_PER_TX: 4,
});

class AppError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.details = details;
  }
}

function ok(data) {
  return Object.assign({ ok: true }, data);
}

function fail(err) {
  const out = {
    ok: false,
    code: err && err.code ? err.code : Code.INTERNAL,
    message: err && err.message ? err.message : 'internal error',
  };
  if (err && err.details) out.details = err.details;
  return out;
}

module.exports = { Code, LIMITS, AppError, ok, fail };
