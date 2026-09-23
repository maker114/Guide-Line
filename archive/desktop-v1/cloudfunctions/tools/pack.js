'use strict';

/**
 * 打包云函数：把「共享 common/」变成「每个函数自包含」，供两种部署方式使用。
 *
 *   node tools/pack.js
 *
 * 产物：
 *   dist/cli/<函数名>/         ← CloudBase CLI 用（cloudbaserc.json 里 dir 指向它）
 *   dist/web/<函数名>/         ← 网页控制台「上传文件夹」用
 *   之后由 PowerShell 把 dist/web/<函数名>/ 压成 dist/web/<函数名>.zip
 *
 * 为什么要打包：源码里 index.js 引用的是 `../common/xxx`（共享目录），
 * 而云函数代码根只能是一份自包含代码。打包时把 `../common/` 改写成 `./common/`，
 * 并把 common/ 复制进每个函数目录 —— 源码保持单份，部署包各自独立。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const COMMON_DIR = path.join(ROOT, 'common');
const DIST = path.join(ROOT, 'dist');

const FUNCTIONS = [
  // 同步三件套
  'commitTx',
  'getVersions',
  'getDoc',
  // 身份五件套
  'registerAccount',
  'createPairingCode',
  'pair',
  'issueTicket',
  'rotateRecoveryCode',
];

/** 复制整个目录（不递归太深，cloudfunctions 结构是平的） */
function copyDir(from, to) {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const src = path.join(from, entry.name);
    const dst = path.join(to, entry.name);
    if (entry.isDirectory()) copyDir(src, dst);
    else fs.copyFileSync(src, dst);
  }
}

function rmrf(target) {
  if (fs.existsSync(target)) fs.rmSync(target, { recursive: true, force: true });
}

function packFunction(name, targetRoot) {
  const srcIndex = path.join(ROOT, name, 'index.js');
  if (!fs.existsSync(srcIndex)) throw new Error(`缺少函数入口：${name}/index.js`);

  const dir = path.join(targetRoot, name);
  rmrf(dir);
  fs.mkdirSync(dir, { recursive: true });

  // 1) 入口：把共享引用改写为包内引用
  const code = fs.readFileSync(srcIndex, 'utf8');
  const rewritten = code.replace(/require\('\.\.\/common\//g, "require('./common/");
  if (code === rewritten) {
    throw new Error(`${name}/index.js 未出现 ../common/ 引用，打包规则可能已过期`);
  }
  fs.writeFileSync(path.join(dir, 'index.js'), rewritten);

  // 2) 共享代码整份带进去
  copyDir(COMMON_DIR, path.join(dir, 'common'));

  // 3) 每个函数自己的 package.json（无依赖；云开发运行时内置 @cloudbase/node-sdk）
  fs.writeFileSync(
    path.join(dir, 'package.json'),
    `${JSON.stringify({ name: `guideline-${name}`, version: '0.0.0', private: true, main: 'index.js' }, null, 2)}\n`,
  );

  const files = [];
  const walk = (d, prefix) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) walk(path.join(d, e.name), `${prefix}${e.name}/`);
      else files.push(`${prefix}${e.name}`);
    }
  };
  walk(dir, '');
  return files;
}

rmrf(DIST);
const report = [];
for (const name of FUNCTIONS) {
  const cliFiles = packFunction(name, path.join(DIST, 'cli'));
  const webFiles = packFunction(name, path.join(DIST, 'web'));
  report.push({ name, files: cliFiles.length, web: webFiles.length });
}

console.log(`打包完成：${FUNCTIONS.length} 个函数\n`);
for (const r of report) {
  console.log(`  ${r.name.padEnd(20)} dist/cli/${r.name}/  (${r.files} 个文件)`);
}
console.log('\n下一步：把 dist/web/<函数名>/ 压成 zip（见 README「网页控制台部署」）。');
