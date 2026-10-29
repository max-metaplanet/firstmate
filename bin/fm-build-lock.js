'use strict';
// NODE_OPTIONS preload for the machine-wide heavy slot pool. fm-build-lock.py
// owns the slots, their scope, and the documented limits. Ordinary Node
// processes return after the entry-name check; a heavy command re-runs itself
// in a slot and exits with that run's status.
//
// Heavy means a command whose peak memory can exhaust a small machine: a Next
// production build, a Vitest run, a Playwright browser run, and a whole-project
// tsc. A tsc given a source file type-checks that file and stays unlocked.
const argv = process.argv;
const ENTRIES = new Set(['next', 'vitest.mjs', 'cli.js', 'tsc', 'tsc.js']);
const entry = typeof argv[1] === 'string' ? argv[1].slice(argv[1].lastIndexOf('/') + 1) : '';
const heavy = (script, args) => {
  if (script.endsWith('/next/dist/bin/next')) return args[0] === 'build';
  if (script.endsWith('/vitest/vitest.mjs')) return args[0] === 'run';
  if (script.endsWith('/@playwright/test/cli.js')) return args[0] === 'test';
  if (script.endsWith('/typescript/bin/tsc') || script.endsWith('/typescript/lib/tsc.js')) {
    return !args.some((a) => a === '--version' || a === '-v' || a === '--init' ||
      /\.[cm]?tsx?$/i.test(a));
  }
  return false;
};
if (ENTRIES.has(entry) && process.env.FM_BUILD_LOCK_BYPASS !== '1' &&
    process.env.FM_BUILD_LOCK_HELD !== String(process.pid) &&
    !argv.includes('--help') && !argv.includes('-h')) {
  let script = '';
  try { script = require('fs').realpathSync(argv[1]); } catch {}
  if (heavy(script, argv.slice(2))) {
    const lock = require('path').join(__dirname, 'fm-build-lock.py');
    const result = require('child_process').spawnSync(lock,
      ['--', process.execPath, ...process.execArgv, ...argv.slice(1)], { stdio: 'inherit' });
    if (result.error) {
      console.error(`build lock: ${result.error.message}`);
      process.exit(75);
    }
    if (result.signal) {
      process.kill(process.pid, result.signal);
      process.exit(128 + require('os').constants.signals[result.signal]);
    }
    process.exit(result.status);
  }
}
