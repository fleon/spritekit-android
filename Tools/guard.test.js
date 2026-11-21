'use strict';
// Tools/guard.js: its exit codes, the kill at the limit (the command and what
// it started), and a run through a shim in another directory, as games run it.
// node --test Tools/guard.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const GUARD = path.join(__dirname, 'guard.js');
const node = process.execPath;

function guard(args, script = GUARD) {
  return spawnSync(node, [script, ...args], { encoding: 'utf8', timeout: 30000 });
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

test('a bad command line is a usage error', () => {
  for (const args of [[], ['0', '--', 'true'], ['x', '--', 'true'], ['1', 'true'], ['1', '--']]) {
    const run = guard(args);
    assert.strictEqual(run.status, 2, args.join(' '));
    assert.match(run.stderr, /Usage: node Tools\/guard\.js <GB> -- <command>/);
  }
});

test('exits with the command\'s code and prints the peak', () => {
  const run = guard(['1', '--', node, '-e', 'console.log("out"); process.exit(3)']);
  assert.strictEqual(run.status, 3);
  assert.strictEqual(run.stdout, 'out\n');
  assert.match(run.stderr, /guard: peak \d+\.\d GB/);
});

test('a command that cannot start exits 127', () => {
  const run = guard(['1', '--', 'guard-test-no-such-command']);
  assert.strictEqual(run.status, 127);
  assert.match(run.stderr, /guard: .*ENOENT/);
});

test('kills the command and what it started once together they pass the limit', () => {
  // The child stays small; the grandchild it starts holds 600 MB, so the guard must count it.
  // It prints its pid before it fills, so the kill can't come first.
  const hog = 'console.log(process.pid); const b = Buffer.alloc(600 * 1048576); b.fill(1); setInterval(() => b[0]++, 100);';
  const parent = `require('child_process').spawn(process.execPath, ['-e', ${JSON.stringify(hog)}], { stdio: 'inherit' }); setInterval(() => {}, 1000);`;
  const run = guard(['0.3', '--', node, '-e', parent]);
  assert.strictEqual(run.status, 137, run.stderr);
  assert.match(run.stderr, /guard: killed .* at \d+\.\d GB \(limit 0\.3 GB\)/);
  const pid = Number(run.stdout.trim());
  assert.ok(pid > 0, 'the grandchild printed its pid');
  assert.strictEqual(alive(pid), false, 'the grandchild is gone too');
});

test('runs through a shim that requires it from another directory', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'guard-test-'));
  try {
    const shim = path.join(dir, 'guard.js');
    fs.writeFileSync(shim, `'use strict';\nrequire(${JSON.stringify(GUARD)});\n`);
    const run = guard(['1', '--', node, '-e', 'process.exit(5)'], shim);
    assert.strictEqual(run.status, 5);
    assert.match(run.stderr, /guard: peak/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
