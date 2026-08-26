'use strict'

// Integration tests for the source-only producer boundary used by every
// persistent QML StdioCollector. These execute only short-lived child
// processes owned by the test.

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')
const { spawn, spawnSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

const HELPER = path.join(__dirname, '..', 'bin', 'bounded-command')
const EXIT_ARGS = 64
const EXIT_OVERFLOW = 74
const EXIT_NOT_FOUND = 127

const LOAD_MODULE = [
  'import importlib.machinery, importlib.util, sys',
  'loader = importlib.machinery.SourceFileLoader("bounded_command_module", sys.argv[1])',
  'spec = importlib.util.spec_from_loader("bounded_command_module", loader)',
  'module = importlib.util.module_from_spec(spec)',
  'loader.exec_module(module)'
].join('\n')

function run(args) {
  const result = spawnSync(HELPER, args, { encoding: 'utf8', timeout: 5000 })
  assert.equal(result.error, undefined, `bounded-command failed to launch: ${result.error}`)
  return result
}

function waitForExit(child, timeoutMs = 5000) {
  if (child.exitCode !== null || child.signalCode !== null)
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timed out waiting for bounded-command')), timeoutMs)
    child.once('exit', (code, signal) => {
      clearTimeout(timer)
      resolve({ code, signal })
    })
  })
}

async function childPidOf(parentPid, timeoutMs = 2000) {
  const childrenPath = `/proc/${parentPid}/task/${parentPid}/children`
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const value = fs.readFileSync(childrenPath, 'utf8').trim()
      if (value) return Number(value.split(/\s+/)[0])
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
    }
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  throw new Error(`bounded-command ${parentPid} never spawned its child`)
}

function assertProcessGone(pid, label) {
  assert.throws(() => process.kill(pid, 0), error => error.code === 'ESRCH',
    `${label} PID ${pid} survived producer-group cleanup`)
}

describe('bounded-command helper', () => {
  it('is shipped as executable, reviewable Python source', () => {
    const stat = fs.statSync(HELPER)
    assert.ok(stat.isFile())
    assert.ok(stat.mode & 0o111)
    const raw = fs.readFileSync(HELPER)
    assert.ok(!raw.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46])))
    const source = new TextDecoder('utf-8', { fatal: true }).decode(raw)
    assert.equal(source.split('\n', 1)[0], '#!/usr/bin/python3')
    const compiled = spawnSync('/usr/bin/python3', [
      '-c', 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")', HELPER
    ], { encoding: 'utf8' })
    assert.equal(compiled.status, 0, compiled.stderr)
  })

  it('forwards successful stdout at the exact byte cap', () => {
    const result = run(['3', '/usr/bin/printf', '%s', 'abc'])
    assert.equal(result.status, 0)
    assert.equal(result.stdout, 'abc')
    assert.equal(result.stderr, '')
  })

  it('kills an overflowing producer group without forwarding partial output', () => {
    const started = Date.now()
    const result = run(['1024', '/usr/bin/yes'])
    assert.equal(result.status, EXIT_OVERFLOW)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, /^bounded-command: output exceeded 1024 bytes; child killed\n$/)
    assert.ok(Date.now() - started < 3000, 'overflowing producer was not stopped promptly')
  })

  it('kills descendants that remain in an overflowing producer group', async () => {
    const producerCode = [
      'import subprocess, sys, time',
      'subprocess.Popen(["/usr/bin/sleep", "30"])',
      'time.sleep(0.2)',
      'sys.stdout.write("x" * 2048)',
      'sys.stdout.flush()',
      'time.sleep(30)'
    ].join('; ')
    const wrapper = spawn(HELPER, [
      '1024', '/usr/bin/python3', '-c', producerCode
    ], { stdio: ['ignore', 'pipe', 'pipe'] })
    const producerPid = await childPidOf(wrapper.pid)
    const descendantPid = await childPidOf(producerPid)
    const result = await waitForExit(wrapper)
    assert.equal(result.code, EXIT_OVERFLOW)
    assert.equal(result.signal, null)
    assertProcessGone(producerPid, 'producer')
    assertProcessGone(descendantPid, 'descendant')
  })

  it('stays bounded when a hard deadline kills a TERM-resistant producer', () => {
    const started = Date.now()
    const producerCode = [
      'import signal, time',
      'signal.signal(signal.SIGTERM, signal.SIG_IGN)',
      'time.sleep(30)'
    ].join('; ')
    const result = run([
      '1024',
      'timeout', '--kill-after=0.1', '0.1',
      '/usr/bin/python3', '-c', producerCode
    ])
    assert.notEqual(result.status, 0)
    assert.equal(result.stdout, '')
    assert.equal(result.stderr, '')
    assert.ok(Date.now() - started < 2000,
      'TERM-resistant producer outlived its hard deadline')
  })

  it('rejects invalid and excessive caps before spawning', () => {
    for (const cap of ['', '0', '-1', '12.5', 'abc', '8388609', '9'.repeat(32)]) {
      const result = run([cap, '/usr/bin/true'])
      assert.equal(result.status, EXIT_ARGS, `cap ${cap}`)
      assert.equal(result.stdout, '')
      assert.match(result.stderr, /^bounded-command:/)
    }
    const missingCommand = run(['1'])
    assert.equal(missingCommand.status, EXIT_ARGS)
  })

  it('reports a missing command with bounded diagnostics', () => {
    const result = run(['1024', '/definitely/missing/system-monitor-command'])
    assert.equal(result.status, EXIT_NOT_FOUND)
    assert.equal(result.stdout, '')
    assert.match(result.stderr, /^bounded-command: command not found:/)
    assert.ok(Buffer.byteLength(result.stderr) < 128)
  })

  it('suppresses stdout and producer stderr when the producer fails', () => {
    const stdoutResult = run([
      '1024', '/usr/bin/awk', 'BEGIN { print "partial"; exit 23 }'
    ])
    assert.equal(stdoutResult.status, 23)
    assert.equal(stdoutResult.stdout, '')
    assert.equal(stdoutResult.stderr, '')

    const stderrResult = run(['1024', '/usr/bin/ls', '--definitely-invalid-system-monitor-option'])
    assert.notEqual(stderrResult.status, 0)
    assert.equal(stderrResult.stdout, '')
    assert.equal(stderrResult.stderr, '')
  })

  it('passes injection-shaped arguments literally without a shell', () => {
    const payload = '$(touch /tmp/never-system-monitor) ; `id` | cat'
    const result = run(['1024', '/usr/bin/printf', '%s', payload])
    assert.equal(result.status, 0)
    assert.equal(result.stdout, payload)
    assert.equal(result.stderr, '')
  })

  it('kills and reaps the child group when the wrapper is cancelled', async () => {
    const wrapper = spawn(HELPER, ['1024', '/usr/bin/sleep', '30'], {
      stdio: ['ignore', 'pipe', 'pipe']
    })
    const producerPid = await childPidOf(wrapper.pid)
    wrapper.kill('SIGTERM')
    const result = await waitForExit(wrapper)
    assert.equal(result.code, 143)
    assert.equal(result.signal, null)
    assertProcessGone(producerPid, 'producer')
  })

  it('clears child ownership before post-reap cancellation', () => {
    const script = [
      LOAD_MODULE,
      'class FakeProcess:',
      '    pid = 2147483647',
      '    returncode = None',
      '    def poll(self):',
      '        self.returncode = 0',
      '        return 0',
      'fake = FakeProcess()',
      'module._child = fake',
      'assert module.reap_owned_child(fake) == 0',
      'assert module._child is None',
      'module.kill_group = lambda proc: (_ for _ in ()).throw(AssertionError("stale kill"))',
      'module.os._exit = lambda code: (_ for _ in ()).throw(SystemExit(code))',
      'try:',
      '    module._on_signal(module.signal.SIGTERM, None)',
      'except SystemExit as error:',
      '    assert error.code == 143',
      'print("ownership-cleared")'
    ].join('\n')
    const result = spawnSync('/usr/bin/python3', [
      '-B', '-c', script, HELPER
    ], { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout.trim(), 'ownership-cleared')
    assert.equal(result.stderr, '')
  })
})
