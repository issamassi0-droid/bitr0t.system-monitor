'use strict'

// Integration test for the colocated `bin/pidfd-signal` helper: a
// standard-library Python script shipped as reviewable source (no compiled
// artifact). It spawns real child processes and proves the race-free
// contract end to end —
//   * the shipped helper is executable, readable Python — not an ELF —
//     and the C helper it replaces is gone,
//   * a wrong identity token must leave the child untouched (exit 4),
//   * the token real `LC_ALL=C ps -o lstart=` reports must terminate the
//     child via SIGTERM (exit 0) — which also proves the helper's
//     /proc-derived token is ps-compatible on this machine,
//   * garbage arguments and vanished PIDs must fail without signalling
//     (exits 2 and 3),
//   * the /proc/PID/stat parser survives a comm field containing spaces
//     and nested parentheses.
// Never signals anything but children this test spawned itself.

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { spawn, spawnSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

const HELPER = path.join(__dirname, '..', 'bin', 'pidfd-signal')
const RETIRED_C_HELPER = path.join(__dirname, '..', 'native', 'pidfd-signal.c')

const EXIT_ARGS = 2
const EXIT_VANISHED = 3
const EXIT_MISMATCH = 4

// Loads the production helper as a Python module. The helper has no .py
// extension, so a SourceFileLoader is required (spec_from_file_location
// returns null for extensionless files). Importing must not run main —
// the helper guards it with `if __name__ == "__main__"`.
const LOAD_MODULE = [
  'import importlib.machinery, importlib.util, sys',
  'loader = importlib.machinery.SourceFileLoader("pidfd_signal_module", sys.argv[1])',
  'spec = importlib.util.spec_from_loader("pidfd_signal_module", loader)',
  'module = importlib.util.module_from_spec(spec)',
  'loader.exec_module(module)'
].join('\n')

function runHelper(args) {
  const res = spawnSync(HELPER, args, { encoding: 'utf8' })
  assert.ok(res.error === undefined, `helper failed to launch: ${res.error}`)
  return res
}

function psLstart(pid) {
  const res = spawnSync('ps', ['-p', String(pid), '-o', 'lstart='], {
    encoding: 'utf8',
    env: Object.assign({}, process.env, { LC_ALL: 'C' })
  })
  assert.equal(res.status, 0, `ps could not read PID ${pid}`)
  return res.stdout.trim().split(/\s+/).join(' ')
}

function stillAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (err) {
    return err.code === 'EPERM'
  }
}

function waitForExit(child, timeoutMs = 10000) {
  if (child.exitCode !== null || child.signalCode !== null)
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`timed out waiting for PID ${child.pid} to exit`)),
      timeoutMs)
    child.once('exit', (code, signal) => {
      clearTimeout(timer)
      resolve({ code, signal })
    })
  })
}

describe('pidfd-signal helper', () => {
  it('is shipped as executable, reviewable Python source (no ELF, no C)', () => {
    const st = fs.statSync(HELPER)
    assert.ok(st.isFile(), `${HELPER} is missing`)
    assert.ok(st.mode & 0o111, `${HELPER} is not executable`)

    // Source text, never a committed binary.
    const raw = fs.readFileSync(HELPER)
    assert.ok(!raw.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46])),
      `${HELPER} must not ship as an ELF binary`)
    let source
    try {
      source = new TextDecoder('utf-8', { fatal: true }).decode(raw)
    } catch (err) {
      assert.fail(`${HELPER} is not UTF-8 source text: ${err}`)
    }
    assert.equal(source.split('\n', 1)[0], '#!/usr/bin/python3',
      'helper must run directly on the system python3')

    // The whole file parses as Python.
    const compiled = spawnSync('/usr/bin/python3',
      ['-c', 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")', HELPER],
      { encoding: 'utf8' })
    assert.ok(compiled.error === undefined, `python3 failed to launch: ${compiled.error}`)
    assert.equal(compiled.status, 0, `helper is not valid Python: ${compiled.stderr}`)

    // The C helper this script replaced is gone for good.
    assert.throws(() => fs.statSync(RETIRED_C_HELPER), /ENOENT/,
      'native/pidfd-signal.c must no longer exist')
  })

  it('refuses garbage arguments without signalling anything (exit 2)', () => {
    for (const bad of ['-1', '12.5', 'abc', '', '1;reboot', '0']) {
      const res = runHelper([bad, 'Mon Jan 1 00:00:00 2026'])
      assert.equal(res.status, EXIT_ARGS, `pid '${bad}' should be rejected`)
      assert.match(res.stderr, /pidfd-signal:/)
    }
    const emptyToken = runHelper(['123', '   '])
    assert.equal(emptyToken.status, EXIT_ARGS, 'empty identity token must be refused')
    const optionToken = runHelper(['123', '  --version'])
    assert.equal(optionToken.status, EXIT_ARGS,
      'option-shaped identity token must be refused')
    const longToken = runHelper(['123', 'x'.repeat(300)])
    assert.equal(longToken.status, EXIT_ARGS,
      'unbounded identity token must be refused')
    const noArgs = runHelper([])
    assert.equal(noArgs.status, EXIT_ARGS)
  })

  it('leaves the child alive when the identity token is wrong (exit 4)', async () => {
    const child = spawn('sleep', ['30'])
    const pid = child.pid
    assert.ok(stillAlive(pid), 'child should be alive after spawn')

    const res = runHelper([String(pid), 'Mon Jan  1 00:00:00 1999'])
    assert.equal(res.status, EXIT_MISMATCH)
    assert.match(res.stderr, /is now/)
    assert.ok(stillAlive(pid), 'a mismatched token must never signal the process')

    // A real token with an altered year must still mismatch.
    const token = psLstart(pid)
    const wrongYear = token.split(' ').slice(0, -1).concat(['2001']).join(' ')
    const res2 = runHelper([String(pid), wrongYear])
    assert.equal(res2.status, EXIT_MISMATCH, `altered token '${wrongYear}' must mismatch`)
    assert.ok(stillAlive(pid), 'child must still be alive after both refusals')

    child.kill('SIGKILL')
    await waitForExit(child)
  })

  it('terminates the child on its real ps lstart token via SIGTERM (exit 0)', async () => {
    const child = spawn('sleep', ['30'])
    const pid = child.pid
    assert.ok(stillAlive(pid), 'child should be alive after spawn')
    const exitPromise = waitForExit(child)

    // The token the production flow would carry: what `LC_ALL=C ps` prints.
    const token = psLstart(pid)
    // Whitespace-padded spelling still confirms (both sides normalize).
    const res = runHelper([String(pid), '  ' + token.split(' ').join('  ') + ' '])
    assert.equal(res.status, 0, `helper stderr: ${res.stderr}`)

    const exitArgs = await exitPromise
    assert.equal(exitArgs.code, null)
    assert.equal(exitArgs.signal, 'SIGTERM')
  })

  it('fails on a vanished PID without signalling a replacement (exit 3)', async () => {
    // Spawn, reap, then probe the now-free PID. Linux allocates PIDs
    // sequentially, so immediate reuse is not observed in practice; if it
    // ever were, the helper would answer mismatch (4) — also a refusal —
    // so both codes prove "never signalled as the selected process".
    const child = spawn('sleep', ['0.05'])
    const pid = child.pid
    await waitForExit(child)
    const res = runHelper([String(pid), psLstart(process.pid)])
    assert.ok(res.status === EXIT_VANISHED || res.status === EXIT_MISMATCH,
      `expected refusal, got exit ${res.status}: ${res.stderr}`)
    assert.match(res.stderr, /pidfd-signal:/)
  })

  it('parses /proc/PID/stat with spaces and nested parentheses in comm', () => {
    // A synthetic stat line whose comm field contains both spaces and
    // nested parentheses — exactly what a naive whitespace split gets
    // wrong. Fields 4..21 are placeholders; field 22 (starttime) is the
    // ticks value the parser must return. Loading the module must not
    // execute main (it is __main__-guarded), or this would exit non-zero
    // with the usage error on stderr.
    const fields = Array.from({ length: 18 }, (_, i) => `x${i + 4}`)
    const statLine = `31337 (weird )pro(g nam)e) S ${fields.join(' ')} 987654321 107 0`
    const res = spawnSync('/usr/bin/python3',
      ['-B', '-c', `${LOAD_MODULE}\nprint(module.parse_starttime(sys.argv[2]))`, HELPER, statLine],
      { encoding: 'utf8' })
    assert.ok(res.error === undefined, `python3 failed to launch: ${res.error}`)
    assert.equal(res.status, 0, `loading the helper module failed: ${res.stderr}`)
    assert.equal(res.stderr, '', 'importing the helper must not run main')
    assert.equal(res.stdout.trim(), '987654321')
  })
})
