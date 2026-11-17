'use strict';
// Runs a command and kills it, with every process it started, once their
// resident memory together passes the limit, so a runaway script can't take
// the machine down with it (Node's own heap limit misses typed arrays and
// native libraries). Prints the peak when the command ends, and exits with
// the command's code, or 137 when it was killed.
// Usage: node Tools/guard.js <GB> -- <command> [args...]
const { spawn, execFileSync } = require('child_process');

const POLL_MS = 250;
const KB_PER_GB = 1048576;

const [limitArg, dashes, command, ...args] = process.argv.slice(2);
const limit = Number(limitArg);
if (!(limit > 0) || dashes !== '--' || !command) {
  console.error('Usage: node Tools/guard.js <GB> -- <command> [args...]');
  process.exit(2);
}

const child = spawn(command, args, { stdio: 'inherit' });

// The child and everything below it, with their memory together in GB.
function tree() {
  const rows = execFileSync('ps', ['-axo', 'pid=,ppid=,rss='], { encoding: 'utf8' })
    .trim().split('\n').map((line) => line.trim().split(/\s+/).map(Number));
  const ids = new Set([child.pid]);
  for (let grew = true; grew;) {
    grew = false;
    for (const [pid, ppid] of rows) if (ids.has(ppid) && !ids.has(pid)) { ids.add(pid); grew = true; }
  }
  const gb = rows.reduce((sum, [pid, , rss]) => sum + (ids.has(pid) ? rss : 0), 0) / KB_PER_GB;
  return { ids, gb };
}

function killTree() {
  let ids = [child.pid];
  try { ids = [...tree().ids]; } catch { /* ps failed: kill the child alone */ }
  for (const pid of ids) { try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ } }
}

let peak = 0;
let killed = false;
const timer = setInterval(() => {
  let gb;
  try { ({ gb } = tree()); } catch { return; }
  peak = Math.max(peak, gb);
  if (gb > limit && !killed) {
    killed = true;
    console.error(`guard: killed ${command} at ${gb.toFixed(1)} GB (limit ${limit} GB)`);
    killTree();
  }
}, POLL_MS);

// If the guard itself is stopped (a tool's timeout, a session ending), the command goes with it.
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => { killTree(); process.exit(130); });

child.on('error', (error) => { clearInterval(timer); console.error(`guard: ${error.message}`); process.exit(127); });
child.on('exit', (code) => {
  clearInterval(timer);
  console.error(`guard: peak ${peak.toFixed(1)} GB`);
  process.exit(killed ? 137 : code ?? 1);
});
