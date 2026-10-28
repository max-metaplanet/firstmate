'use strict';
// NODE_OPTIONS preload for the machine-wide heavy build lock. fm-build-lock.py
// owns the lock, its scope, and the documented limits. Ordinary Node processes
// return after the argv check; a Next production build re-runs itself under the
// lock and exits with that run's status.
const argv = process.argv;
if (argv[2] === 'build' && process.env.FM_BUILD_LOCK_BYPASS !== '1' &&
    process.env.FM_BUILD_LOCK_HELD !== String(process.pid) &&
    !argv.includes('--help') && !argv.includes('-h')) {
  let script = '';
  try { script = require('fs').realpathSync(argv[1]); } catch {}
  if (script.endsWith('/next/dist/bin/next')) {
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
