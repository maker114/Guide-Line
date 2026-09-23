'use strict';

/**
 * 版本无关的测试运行器。
 *
 * 背景：`node:test` 需要 Node 18+，而本机可能只有 Node 14/16（例如 Adobe 捆绑的运行时）。
 * 本文件在加载测试文件之前，把 `node:test` 与 `node:assert/strict` 映射到本地最小实现，
 * 全部用例在**同一进程内**顺序执行（不 spawn 子进程，规避沙箱的管道限制）。
 *
 *   node test/run.js          # 任意 Node 14+
 *   node --test test/         # Node 18+ 的原生运行器（等价）
 */

const fs = require('fs');
const path = require('path');
const Module = require('module');
const assert = require('assert');

const cases = [];

function testShim(name, fn) {
  cases.push({ name, fn });
}
testShim.skip = () => {};
testShim.only = (name, fn) => cases.push({ name, fn });
testShim.test = testShim;
testShim.describe = (_name, fn) => fn();

const originalLoad = Module._load;
Module._load = function patchedLoad(request) {
  if (request === 'node:test' || request === 'test') return testShim;
  if (request === 'node:assert/strict' || request === 'assert/strict') return assert.strict;
  return originalLoad.apply(this, arguments);
};

const testFiles = fs
  .readdirSync(__dirname)
  .filter((f) => f.endsWith('.test.js'))
  .sort();

for (const f of testFiles) {
  require(path.join(__dirname, f));
}

(async function main() {
  let passed = 0;
  const failures = [];

  console.log(`运行 ${testFiles.length} 个测试文件，共 ${cases.length} 个用例：\n`);

  for (const c of cases) {
    try {
      await c.fn();
      passed += 1;
      console.log(`  ok    ${c.name}`);
    } catch (err) {
      failures.push({ name: c.name, err });
      console.log(`  FAIL  ${c.name}`);
    }
  }

  console.log(`\n${passed}/${cases.length} passed`);

  if (failures.length > 0) {
    for (const f of failures) {
      console.log(`\n--- ${f.name} ---`);
      console.log(f.err && f.err.stack ? f.err.stack : String(f.err));
    }
  }

  process.exit(failures.length === 0 ? 0 : 1);
})();
