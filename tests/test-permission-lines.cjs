// tests/test-permission-lines.cjs
// 验证 buildPermissionLines：构造 Notification(permission_prompt) 权限确认通知的文本行
//
// 运行：node tests/test-permission-lines.cjs

const assert = require('assert');
const { buildPermissionLines } = require('../src/claude-windows-toast.cjs');

let passed = 0;
function check(name, fn) { fn(); passed++; console.log('  ✓ ' + name); }

console.log('test-permission-lines: buildPermissionLines');

check('非空 message：标题 + message + 目录 三行', () => {
  const lines = buildPermissionLines('Claude needs your permission', 'myproj');
  assert.strictEqual(lines[0], '🔴 Claude Code - 需要你的授权');
  assert.strictEqual(lines[1], 'Claude needs your permission');
  assert.strictEqual(lines[2], '目录: myproj');
});

check('空 message：message 行为空字符串（由 sendToast 过滤）', () => {
  const lines = buildPermissionLines('', 'myproj');
  assert.strictEqual(lines[0], '🔴 Claude Code - 需要你的授权');
  assert.strictEqual(lines[1], '');
  assert.strictEqual(lines[2], '目录: myproj');
});

check('null/undefined message 视为空', () => {
  assert.strictEqual(buildPermissionLines(null, 'p')[1], '');
  assert.strictEqual(buildPermissionLines(undefined, 'p')[1], '');
});

check('前后空白 message 被 trim 为空', () => {
  assert.strictEqual(buildPermissionLines('   ', 'p')[1], '');
});

check('超长 message 截断到 150 字符 + ...', () => {
  const long = 'x'.repeat(200);
  const line = buildPermissionLines(long, 'p')[1];
  assert.strictEqual(line.length, 153); // 150 + '...'
  assert.ok(line.endsWith('...'));
});

check('正好 150 字符不截断（锁定 truncate 的 > vs >= 边界）', () => {
  const exact = 'x'.repeat(150);
  const line = buildPermissionLines(exact, 'p')[1];
  assert.strictEqual(line.length, 150);
  assert.strictEqual(line, exact);
});

check('行数恒为 3', () => {
  assert.strictEqual(buildPermissionLines('m', 'c').length, 3);
  assert.strictEqual(buildPermissionLines('', 'c').length, 3);
});

console.log('\n✅ 全部 ' + passed + ' 个用例通过');
