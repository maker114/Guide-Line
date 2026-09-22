'use strict';

/**
 * Dart 源码静态闸门（在没有 Flutter/Dart SDK 时能做的检查）。
 *
 *   node tools/check-dart-contract.js
 *
 * 三件事：
 *   1. 括号 / 方括号 / 花括号平衡（先剥离字符串与注释）—— 抓住"文件被截断"这类致命错误；
 *   2. 每个实体 `toJson()` 里 key 的**出现顺序**必须与《数据契约》§3 完全一致
 *      （顺序错了，跨端逐字节比对照样会挂，但编译器不会报错）；
 *   3. `knownKeys` 集合必须与同一份字段清单一致（决定未知字段透传是否正确）。
 *
 * 这不是编译器：类型错误仍需 `dart analyze`。它的价值是把"静默损坏"类错误提前挡住。
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

const ENTITIES = [
  {
    file: 'lib/core/models/inspiration.dart',
    name: 'Inspiration',
    fields: ['id', 'text', 'project_id', 'status', 'merged_into', 'merged_at', 'created_at', 'updated_at', 'deleted'],
  },
  {
    file: 'lib/core/models/project.dart',
    name: 'Project',
    fields: ['id', 'title', 'purpose', 'implementation', 'date', 'status', 'archived', 'parent_project_id', 'order', 'completed_at', 'created_at', 'updated_at', 'deleted'],
  },
  {
    file: 'lib/core/models/event.dart',
    name: 'Event',
    fields: ['id', 'name', 'status', 'archived', 'order', 'completed_at', 'created_at', 'updated_at', 'deleted'],
  },
  {
    file: 'lib/core/models/task.dart',
    name: 'Task',
    fields: ['id', 'event_id', 'parent_task_id', 'task_type', 'title', 'due_at', 'status', 'archived', 'order', 'completed_at', 'created_at', 'updated_at', 'deleted'],
  },
];

const TOMBSTONE = {
  file: 'lib/core/models/entity.dart',
  name: 'Tombstone',
  fields: ['id', 'deleted', 'purged_at'],
  toJsonMarker: 'toJson() => <String, dynamic>{',
  skipKnownKeys: true,
};

const problems = [];

/** 剥离字符串与注释，返回可用于括号配对的文本 */
function stripLiterals(text) {
  let out = '';
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];

    if (ch === '/' && next === '/') {
      while (i < text.length && text[i] !== '\n') i += 1;
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i += 1;
      i += 2;
      continue;
    }
    if (ch === "'" || ch === '"') {
      const quote = ch;
      const triple = text.substr(i, 3) === quote.repeat(3);
      const end = triple ? quote.repeat(3) : quote;
      i += end.length;
      while (i < text.length) {
        if (text[i] === '\\') {
          i += 2;
          continue;
        }
        if (text.substr(i, end.length) === end) {
          i += end.length;
          break;
        }
        i += 1;
      }
      out += '""';
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}

function checkBalance(file, text) {
  const stripped = stripLiterals(text);
  const pairs = { ')': '(', ']': '[', '}': '{' };
  const stack = [];
  for (let i = 0; i < stripped.length; i += 1) {
    const ch = stripped[i];
    if (ch === '(' || ch === '[' || ch === '{') stack.push({ ch, i });
    else if (pairs[ch]) {
      const top = stack.pop();
      if (!top || top.ch !== pairs[ch]) {
        problems.push(`${file}: 第 ${countLines(stripped, i)} 行括号不匹配（遇到 ${ch}）`);
        return;
      }
    }
  }
  if (stack.length > 0) {
    problems.push(`${file}: 有 ${stack.length} 个未闭合的括号（最早的 ${stack[0].ch} 在第 ${countLines(stripped, stack[0].i)} 行）`);
  }
}

function countLines(text, index) {
  let n = 1;
  for (let i = 0; i < index && i < text.length; i += 1) {
    if (text[i] === '\n') n += 1;
  }
  return n;
}

function extractQuotedKeys(block) {
  const keys = [];
  const re = /'([a-z0-9_]+)'\s*:/g;
  let m;
  while ((m = re.exec(block)) !== null) keys.push(m[1]);
  return keys;
}

function sliceBlock(text, startMarker) {
  const start = text.indexOf(startMarker);
  if (start === -1) return null;
  let depth = 0;
  let i = start + startMarker.length - 1;
  for (; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    else if (text[i] === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return null;
}

function checkEntity(entity) {
  const full = path.join(ROOT, entity.file);
  const text = fs.readFileSync(full, 'utf8');

  const toJsonBlock = sliceBlock(text, entity.toJsonMarker || 'final out = <String, dynamic>{');
  if (!toJsonBlock) {
    problems.push(`${entity.file}: 找不到 toJson() 的字段映射表`);
  } else {
    const keys = extractQuotedKeys(toJsonBlock);
    if (keys.join(',') !== entity.fields.join(',')) {
      problems.push(
        `${entity.file}: toJson() 字段顺序与契约不符\n      期望: ${entity.fields.join(', ')}\n      实际: ${keys.join(', ')}`,
      );
    }
  }

  if (entity.skipKnownKeys) return;

  const knownBlock = sliceBlock(text, 'static const Set<String> knownKeys = <String>{');
  if (!knownBlock) {
    problems.push(`${entity.file}: 找不到 knownKeys`);
  } else {
    const keys = (knownBlock.match(/'([a-z0-9_]+)'/g) || []).map((s) => s.replace(/'/g, ''));
    const expected = entity.fields.slice().sort();
    const actual = keys.slice().sort();
    if (expected.join(',') !== actual.join(',')) {
      problems.push(
        `${entity.file}: knownKeys 与契约字段不一致\n      期望: ${expected.join(', ')}\n      实际: ${actual.join(', ')}`,
      );
    }
  }
}

function collectDartFiles(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) collectDartFiles(full, out);
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

// ---- 执行 ----

const dartFiles = [];
for (const dir of ['lib', 'test']) {
  const full = path.join(ROOT, dir);
  if (fs.existsSync(full)) collectDartFiles(full, dartFiles);
}

for (const file of dartFiles) {
  const rel = path.relative(ROOT, file).replace(/\\/g, '/');
  const text = fs.readFileSync(file, 'utf8');
  checkBalance(rel, text);
  if (text.indexOf('\r') !== -1) problems.push(`${rel}: 含 CR（Dart 源码统一 LF）`);
  if (!text.endsWith('\n')) problems.push(`${rel}: 末尾缺少换行`);
  if (/[ \t]+$/m.test(text)) problems.push(`${rel}: 存在行尾空白`);
}

for (const entity of ENTITIES.concat([TOMBSTONE])) checkEntity(entity);

console.log(`检查 ${dartFiles.length} 个 Dart 文件：`);
for (const file of dartFiles) {
  console.log(`  ok    ${path.relative(ROOT, file).replace(/\\/g, '/')}`);
}

if (problems.length > 0) {
  console.log(`\n✗ 发现 ${problems.length} 个问题：`);
  for (const p of problems) console.log(`  - ${p}`);
  process.exit(1);
}
console.log('\n✓ 括号平衡、行尾与「toJson 字段顺序 / knownKeys」均与《数据契约》一致');
