'use strict';
// NODE_OPTIONS preload for the machine-wide heavy slot pool. fm-build-lock.py
// owns the slots, their scope, and the documented limits. Ordinary Node
// processes return after the entry-name check; a heavy command re-runs itself
// in a slot and exits with that run's status.
//
// Heavy means a command whose peak memory can exhaust a small machine: a Next
// production build, a Vitest run (a bare vitest runs once off a TTY or in CI,
// as Vitest does), a Playwright browser run, an ESLint run, and a whole-project
// tsc. A tsc or eslint given a source file checks that one file and stays
// unlocked, as does a tsc in watch mode, which never exits and would hold its
// slot forever.
//
// A package script named by FM_HEAVY_SCRIPTS (comma-separated, default
// `preflight,queue-preflight`, and empty to name none) is heavy as a whole
// rather than per command: it runs many heavy commands in sequence, so the
// script's own process claims one slot for the entire run, its heavy children
// reuse that slot instead of taking another, and everything it starts is inside
// the slot's memory cgroup. Only the outermost process claims, because inside a
// slot FM_BUILD_LOCK_HELD is already set.
//
// Two things strip this preload back out of a child in practice. A script that
// ASSIGNS NODE_OPTIONS instead of appending to it drops the --require; every
// spawn made from a process carrying this preload gets that --require put back,
// which is what keeps a child heavy command locked and capped. A launcher that
// rebuilds the child environment from a name allowlist leaves no NODE_OPTIONS
// to repair; there the enclosing heavy package script's cgroup is the cover,
// because a cgroup is inherited through exec no matter what the environment
// says.
const argv = process.argv;
const ENTRIES = new Set(['next', 'vitest', 'vitest.mjs', 'playwright', 'cli.js', 'tsc', 'tsc.js',
  'eslint', 'eslint.js']);
// One named source file, so a per-file check stays unlocked. A bare extension
// such as the `.ts` of `--ext .ts` is a flag value, not a file, and must not
// exempt the run.
const SOURCE_FILE = /[^/\\]\.[cm]?[jt]sx?$/i;
const SCRIPTS = new Set((process.env.FM_HEAVY_SCRIPTS ?? 'preflight,queue-preflight')
  .split(',').map((name) => name.trim()).filter(Boolean));
const OPTION = `--require=${__filename}`;
// NODE_OPTIONS is split on whitespace and embedded in shells, so a path that is
// not safe there is left alone rather than corrupting every child's options.
const SAFE_OPTION = /^--require=[A-Za-z0-9/._\-=+]+$/.test(OPTION);
const PROMISIFY = Symbol.for('nodejs.util.promisify.custom');
const entry = typeof argv[1] === 'string' ? argv[1].slice(argv[1].lastIndexOf('/') + 1) : '';
const heavy = (script, args) => {
  const command = args.find((a) => !a.startsWith('-'));
  if (script.endsWith('/next/dist/bin/next')) return command === 'build';
  if (script.endsWith('/vitest/vitest.mjs')) {
    if (args.includes('--version') || args.includes('-v')) return false;
    if (args.includes('run') || args.includes('--run')) return true;
    if (command === 'watch' || command === 'dev' || args.includes('--watch') ||
        args.includes('-w')) return false;
    return !process.stdin.isTTY || Boolean(process.env.CI);
  }
  if (script.endsWith('/@playwright/test/cli.js') ||
      script.endsWith('/playwright/cli.js')) return command === 'test';
  if (script.endsWith('/eslint/bin/eslint.js')) {
    return !args.some((a) => a === '--version' || a === '-v' || a === '--init' ||
      a === '--print-config' || SOURCE_FILE.test(a));
  }
  if (script.endsWith('/typescript/bin/tsc') || script.endsWith('/typescript/lib/tsc.js')) {
    return !args.some((a) => a === '--version' || a === '-v' || a === '--init' ||
      a === '--watch' || a === '-w' ||
      SOURCE_FILE.test(a));
  }
  return false;
};
// Re-runs this process in a slot and exits with that run's status.
const relaunch = () => {
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
};
// Puts this preload back into a child NODE_OPTIONS the caller assigned, so a
// heavy child of such a spawn still claims a slot. An environment the caller
// did not name inherits this process's own options and needs no repair, and an
// environment with no NODE_OPTIONS at all is left alone: the caller built it
// from scratch, and the enclosing slot's cgroup already bounds it.
const repairChildEnvironments = () => {
  const cp = require('child_process');
  const fix = (options) => {
    const env = options.env;
    if (env === null || typeof env !== 'object') return options;
    const current = env.NODE_OPTIONS;
    if (typeof current !== 'string' || current.trim() === '') return options;
    if (current.includes('fm-build-lock.js')) return options;
    return { ...options, env: { ...env, NODE_OPTIONS: `${current} ${OPTION}` } };
  };
  // The options object is the last argument that is neither an argument list
  // nor a callback, across spawn, exec and fork's several shapes.
  const wrapCall = (original) => function (...args) {
    try {
      for (let i = args.length - 1; i >= 0; i -= 1) {
        const options = args[i];
        if (options === null || typeof options !== 'object' || Array.isArray(options)) continue;
        args[i] = fix(options);
        break;
      }
    } catch { /* an unexpected call shape must never stop the spawn */ }
    return original.apply(this, args);
  };
  const wrap = (original) => {
    const wrapped = wrapCall(original);
    // exec and execFile carry a promisify hook and other own properties that
    // callers reach for; keep them, with the hook wrapped the same way.
    for (const key of Reflect.ownKeys(original)) {
      if (key === 'length' || key === 'prototype') continue;
      try {
        Object.defineProperty(wrapped, key, Object.getOwnPropertyDescriptor(original, key));
      } catch { /* a non-configurable property stays as the wrapper has it */ }
    }
    if (typeof original[PROMISIFY] === 'function') {
      try {
        Object.defineProperty(wrapped, PROMISIFY,
          { value: wrapCall(original[PROMISIFY]), configurable: true });
      } catch { /* leave the original hook in place */ }
    }
    return wrapped;
  };
  for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync',
    'fork']) {
    if (typeof cp[name] !== 'function') continue;
    cp[name] = wrap(cp[name]);
  }
};
if (process.env.FM_BUILD_LOCK_BYPASS !== '1') {
  if (process.env.FM_BUILD_LOCK_HELD !== String(process.pid) &&
      !argv.includes('--help') && !argv.includes('-h')) {
    if (ENTRIES.has(entry)) {
      let script = '';
      try { script = require('fs').realpathSync(argv[1]); } catch {}
      if (heavy(script, argv.slice(2))) relaunch();
    }
    if (!process.env.FM_BUILD_LOCK_HELD && SCRIPTS.has(process.env.npm_lifecycle_event || '')) {
      relaunch();
    }
  }
  if (SAFE_OPTION) {
    try { repairChildEnvironments(); } catch { /* never break a Node process over this */ }
  }
}
