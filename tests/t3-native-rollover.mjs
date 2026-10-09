// Opt-in companion to probe-codex-rollover.py; never a production launcher.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CodexBridge, readLines } from '../src/t3-codex.mjs';

const config = readFileSync(join(process.env.CODEX_HOME, 'config.toml'), 'utf8');
if (!/^openai_base_url = "http:\/\/127\.0\.0\.1:\d+\/v1"$/m.test(config) || !process.env.HOTPL8_FIXTURE_TOKENS) {
  throw new Error('This harness requires the isolated localhost Python fixture');
}
const tokens = JSON.parse(process.env.HOTPL8_FIXTURE_TOKENS);
const policyBroker = process.argv.includes('--policy-broker');
const brokerEvidence = { calls: 0, validatedSlots: [], routingErrors: [] };
// With --policy-broker the account is chosen by the compiled program a release ships,
// started as the bridge starts it. Only what it reads is the fixture's: a stand-in is read
// in place of Codex for each account's facts (native/examples/codex_stand_in.rs, which a
// checkout builds with `cargo build --examples`), beside what a collection would have
// published of the same two accounts.
const root = resolve(fileURLToPath(new URL('../', import.meta.url)));
const windows = process.platform === 'win32';
const routeProgram = join(root, 'bin', ...(windows ? ['windows', 'hotpl8-native.exe'] : [process.platform === 'darwin' ? 'macos' : 'linux', 'hotpl8-native']));
const reader = join(root, 'native', 'target', 'debug', 'examples', windows ? 'codex_stand_in.exe' : 'codex_stand_in');
const routing = resolve(process.env.CODEX_HOME, 'fixture-routing');
const slots = ['a', 'b'];
const address = id => `${id}@example.invalid`;
const save = (name, value) => writeFileSync(join(routing, name), JSON.stringify(value), 'utf8');
const hash = text => createHash('sha256').update(text, 'utf8').digest('hex');
const resets = Math.floor(Date.now() / 1000) + 3 * 86400;
// What each account answers when it is read, and what a collection published of it.
const publish = used => {
  const at = new Date().toISOString().replace('Z', '0000+00:00');
  for (const id of slots) {
    const limits = { rateLimits: { limitId: 'codex', primary: { usedPercent: used[id], windowDurationMins: 10080, resetsAt: resets },
      secondary: null, spendControlReached: false, rateLimitReachedType: null } };
    writeFileSync(join(routing, id, 'stand-in.txt'), [
      'initialize reply {}',
      `account/read reply ${JSON.stringify({ account: { type: 'chatgpt', email: address(id), planType: 'plus' } })}`,
      `account/rateLimits/read reply ${JSON.stringify(limits)}`,
      `config/read reply ${JSON.stringify({ config: { model: 'fixture-model', model_provider: 'openai' } })}`, ''].join('\n'), 'utf8');
  }
  const measured = id => ({ codex: { meter: 'codex', status: 'observed', blockReason: null, warm: 'not applicable: no five-hour window',
    windows: { 10080: { usedPercent: used[id], remainingPercent: 100 - used[id], resetsAt: resets, anchorState: 'unconfirmed', observedAt: at } } } });
  save('status.json', { providers: { codex: { observedAt: at, recommendations: { codex: 'a' },
    slots: slots.map(id => ({ id, status: 'ok', observedAt: at, defaultModel: 'fixture-model', buckets: measured(id) })) } } });
};
const initialize = () => {
  if (!existsSync(routeProgram) || !existsSync(reader)) throw new Error('fixture_broker_unbuilt');
  const recorded = {};
  for (const id of slots) {
    const home = join(routing, id);
    mkdirSync(home, { recursive: true });
    writeFileSync(join(home, 'auth.json'), JSON.stringify({ tokens: { access_token: tokens[id], account_id: `fixture-${id}` } }), 'utf8');
    // Who a collection found the home to belong to, and where the home was.
    recorded[id] = { identityKey: hash(`${address(id)}||fixture-${id}`), binding: hash(home) };
  }
  save('policy.json', { schemaVersion: 2, mode: 'automate', switchEnabled: true, warm: false, probeEnabled: false, prefer: [],
    codex: { slots: slots.map(id => ({ id, home: join(routing, id) })), prefer: slots, order: 'prefer', defaultMeter: 'codex',
      modelMeters: { 'fixture-model': 'codex' }, margin7d: 20, margin7dWork: 5 } });
  save('codex-state.json', { slots: recorded });
  publish({ a: 10, b: 10 });
};
const callPolicyBroker = request => new Promise((resolveRoute, reject) => {
  // The stand-in leaves this file in each home it is started in.
  for (const id of slots) rmSync(join(routing, id, 'started.txt'), { force: true });
  const proc = spawn(routeProgram, ['route', '--root', root, '--state', routing, '--codex', reader], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
  let output = '';
  const timeout = setTimeout(() => { proc.kill(); reject(new Error('fixture_broker_timeout')); }, 25000);
  proc.stdout.setEncoding('utf8'); proc.stdout.on('data', data => { output += data; });
  proc.on('error', err => { clearTimeout(timeout); reject(err); });
  proc.on('close', code => {
    clearTimeout(timeout);
    try {
      const result = JSON.parse(output);
      if (code || result.error) { const err = new Error(result.error || 'fixture_broker_failed'); err.code = err.message; reject(err); return; }
      brokerEvidence.calls++;
      brokerEvidence.validatedSlots.push(...slots.filter(id => existsSync(join(routing, id, 'started.txt'))));
      resolveRoute(result);
    } catch { reject(new Error('fixture_broker_invalid_response')); }
  });
  proc.stdin.on('error', () => {});
  proc.stdin.end(JSON.stringify(request) + '\n');
});
if (policyBroker) {
  try { initialize(); }
  catch {
    // The Python client begins with initialize id1. Report a bounded fixture
    // startup error instead of making it wait for a response from a dead child.
    writeFileSync(1, JSON.stringify({ id: 1, error: { code: -32001, message: 'fixture_broker_initialization_failed' } }) + '\n');
    process.exit(1);
  }
}
let selected = 'a';
const child = spawn(process.argv[2], ['app-server'], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
const write = (stream, message) => stream.write(JSON.stringify(message) + '\n');
const bridge = new CodexBridge({
  cwd: process.cwd(),
  broker: policyBroker ? callPolicyBroker : async request => ({ slot: selected, home: process.env.CODEX_HOME, model: request.model || 'fixture-model', meter: 'codex',
    auth: { accessToken: tokens[selected], chatgptAccountId: `fixture-${selected}`, chatgptPlanType: 'plus' } }),
  toNative: message => write(child.stdin, message), toClient: message => write(process.stdout, message),
  onFatal: () => child.kill(), onRoutingError: code => { brokerEvidence.routingErrors.push(code); }
});
const stop = () => { bridge.close(); child.stdin.end(); };
readLines(child.stdout, message => {
  // The product rejects transport overrides. Only this test harness removes its
  // explicitly verified synthetic localhost transport from native config replies.
  if (message.result?.config) delete message.result.config.openai_base_url;
  bridge.native(message);
}, stop);
readLines(process.stdin, message => {
  if (message.method === 'fixture/rollover') {
    void (async () => {
      if (policyBroker) publish({ a: 96, b: 10 });
      else selected = 'b';
      await bridge.observe();
      write(process.stdout, { id: message.id, result: { selected: bridge.route?.slot, policyBroker, ...brokerEvidence } });
    })().catch(() => write(process.stdout, { id: message.id, error: { code: -32001, message: 'fixture_rollover_failed' } }));
  } else void bridge.client(message);
}, stop, stop);
child.on('exit', code => { bridge.close(); process.exitCode = code || 0; });
