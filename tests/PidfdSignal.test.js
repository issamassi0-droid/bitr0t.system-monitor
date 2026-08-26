'use strict'

// Integration test for the colocated `bin/pidfd-signal` helper: spawns real
// child processes and proves the race-free contract end to end —
//   * a wrong identity token must leave the child untouched (exit 4),
//   * the token real `LC_ALL=C ps -o lstart=` reports must terminate the
//     child via SIGTERM (exit 0) — which also proves the helper's
//     /proc-derived token is ps-compatible on this machine,
//   * garbage arguments and vanished PIDs must fail without signalling
//     (exits 2 and 3).
// Never signals anything but children this test spawned itself.

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { spawn, spawnSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

const HELPER = path.join(__dirname, '..', 'bin', 'pidfd-signal')

const EXIT_ARGS = 2
const EXIT_VANISHED = 3
const EXIT_MISMATCH = 4

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
  it('is shipped executable next to its source', () => {
    const st = fs.statSync(HELPER)
    assert.ok(st.isFile(), `${HELPER} is missing`)
    assert.ok(st.mode & 0o111, `${HELPER} is not executable`)
    assert.ok(fs.statSync(path.join(__dirname, '..', 'native', 'pidfd-signal.c')).isFile())
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
})
