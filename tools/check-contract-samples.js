'use strict';

/**
 * 契约样本格式闸门（任意 Node 14+ 可运行，不需要云环境）。
 *
 *   node tools/check-contract-samples.js
 *
 * 检查项（对应《数据契约》§2 / §6）：
 *   1. 能被解析为 JSON；
 *   2. 无 BOM、只有 LF、文件末尾恰好一个换行；
 *   3. **2 空格缩进 + key 顺序 + 中文不转义** —— 用「解析后再序列化，必须逐字节相同」验证；
 *   4. 文档外层结构合法（version / updated_at / last_tx_id / payload.items）。
 *
 * 这一层是「廉价前置检查」；最终判定仍由 Dart 侧的序列化回归测试逐字节比对完成。
 */

const fs = require('fs');
const path = require('path');

const SAMPLE_DIR = path.join(__dirname, '..', 'test', 'contract', 'sample');
const NAMES = ['projects.json', 'inspirations.json', 'events.json', 'tasks.json'];

const problems = [];

function check(name) {
  const file = path.join(SAMPLE_DIR, name);
  const buf = fs.readFileSync(file);

  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) {
    problems.push(`${name}: 存在 UTF-8 BOM`);
  }
  const raw = buf.toString('utf8');
  if (raw.indexOf('\r') !== -1) problems.push(`${name}: 含 CR（必须只用 LF）`);
  if (!raw.endsWith('\n')) problems.push(`${name}: 末尾缺少换行`);
  if (raw.endsWith('\n\n')) problems.push(`${name}: 末尾多于一个换行`);

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    problems.push(`${name}: JSON 解析失败 —— ${err.message}`);
    return;
  }

  const canonical = JSON.stringify(parsed, null, 2) + '\n';
  if (canonical !== raw) {
    problems.push(`${name}: 与规范形态不一致（缩进/key 顺序/转义）`);
    const a = canonical.split('\n');
    const b = raw.split('\n');
    for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
      if (a[i] !== b[i]) {
        problems.push(`    首个差异在第 ${i + 1} 行：\n      期望: ${JSON.stringify(a[i])}\n      实际: ${JSON.stringify(b[i])}`);
        break;
      }
    }
  }

  if (!Number.isInteger(parsed.version) || parsed.version < 0) problems.push(`${name}: version 必须是 ≥0 的整数`);
  if (!(parsed.updated_at === null || Number.isInteger(parsed.updated_at))) problems.push(`${name}: updated_at 必须是整数或 null`);
  if (!(parsed.last_tx_id === null || typeof parsed.last_tx_id === 'string')) problems.push(`${name}: last_tx_id 必须是字符串或 null`);
  if (!parsed.payload || !Array.isArray(parsed.payload.items)) problems.push(`${name}: payload.items 必须是数组`);

  const items = parsed.payload.items || [];
  let skeletons = 0;
  for (const it of items) {
    if (typeof it.id !== 'string') problems.push(`${name}: 存在缺少 id 的记录`);
    if (typeof it.deleted !== 'boolean') problems.push(`${name}: 记录 ${it.id} 缺少 deleted`);
    const keys = Object.keys(it);
    if (keys.length === 3 && keys.join(',') === 'id,deleted,purged_at') skeletons += 1;
  }

  console.log(`  ok    ${name}  (${items.length} 条记录，其中墓碑骨架 ${skeletons} 个)`);
}

console.log('契约样本检查：');
for (const n of NAMES) check(n);

if (problems.length > 0) {
  console.log(`\n✗ 发现 ${problems.length} 个问题：`);
  for (const p of problems) console.log(`  - ${p}`);
  process.exit(1);
}
console.log('\n✓ 全部样本符合《数据契约》的格式要求');
