// tests/test-session-id.cjs
// 验证 resolveSessionId：从 hook stdin 的 session_id 解析稳定会话标识
//
// 根因：src/claude-windows-toast.cjs 原先用 process.ppid 作会话标识，
// 而 Claude Code 执行 command hook（shell form）时经 sh -c，node 的 ppid
// 是临时 shell 的 PID，每次 spawn 都不同。导致 --mark-ask 写的状态文件
// 与 --stop 读的不是同一个，⏳「等待输入」永不出现。
// 修复：优先用 Claude Code 经 stdin JSON 注入的 session_id（同会话稳定）。
//
// 运行：node tests/test-session-id.cjs

const assert = require('assert');
const { resolveSessionId } = require('../src/claude-windows-toast.cjs');

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log('  ✓ ' + name);
}

console.log('test-session-id: resolveSessionId');

check('stdin session_id 优先使用', () => {
  assert.strictEqual(resolveSessionId({ session_id: 'abc-123' }, {}, 999), 'abc-123');
});

check('stdin session_id 含路径分隔符被清洗为 _（防逃逸 temp 目录）', () => {
  assert.strictEqual(resolveSessionId({ session_id: 'a/b\\c' }, {}, 1), 'a_b_c');
});

check('无 stdin 时回退 CLAUDE_SESSION_ID', () => {
  assert.strictEqual(resolveSessionId({}, { CLAUDE_SESSION_ID: 'env-sid' }, 999), 'env-sid');
});

check('stdin session_id 优先于 env', () => {
  assert.strictEqual(
    resolveSessionId({ session_id: 'from-stdin' }, { CLAUDE_SESSION_ID: 'from-env' }, 1),
    'from-stdin'
  );
});

check('stdin 与 env 都无时回退 ppid', () => {
  assert.strictEqual(resolveSessionId({}, {}, 12345), '12345');
});

check('同会话不同 ppid 解析出同一 SESSION_ID（bug 回归用例）', () => {
  // --mark-ask 进程 ppid=1001，--stop 进程 ppid=1002，但 stdin session_id 相同
  const markAskSid = resolveSessionId({ session_id: 'sess-xyz' }, {}, 1001);
  const stopSid = resolveSessionId({ session_id: 'sess-xyz' }, {}, 1002);
  assert.strictEqual(markAskSid, stopSid);
  assert.strictEqual(markAskSid, 'sess-xyz');
  assert.notStrictEqual(markAskSid, '1001');
  assert.notStrictEqual(stopSid, '1002');
});

check('空字符串 session_id 视为无，回退下一来源', () => {
  assert.strictEqual(
    resolveSessionId({ session_id: '  ' }, { CLAUDE_SESSION_ID: 'env' }, 1),
    'env'
  );
});

check('空字符串 CLAUDE_SESSION_ID 也视为无，回退 ppid（与 stdin 策略一致）', () => {
  assert.strictEqual(resolveSessionId({}, { CLAUDE_SESSION_ID: '   ' }, 777), '777');
});

check('非字符串 session_id 视为无', () => {
  assert.strictEqual(
    resolveSessionId({ session_id: 12345 }, { CLAUDE_SESSION_ID: 'env' }, 1),
    'env'
  );
});

check('超长 session_id 截断到 120 字符', () => {
  const long = 'x'.repeat(200);
  assert.strictEqual(resolveSessionId({ session_id: long }, {}, 1).length, 120);
});

console.log('\n✅ 全部 ' + passed + ' 个用例通过');
