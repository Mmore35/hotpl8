import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { CodexBridge, validateArgs, assertConfig, assertEnvironment, assertSharedHome, readLines } from '../src/t3-codex.mjs';

function harness(options = {}) {
  const native = [], client = [], requests = [];
  let selected = 'a', reject = false, config = { model: 'fixture-model', cli_auth_credentials_store: 'ephemeral' };
  const broker = async request => {
    requests.push(request);
    if (reject) throw Object.assign(new Error(), { code: 'routing_unavailable' });
    const slot = request.operation === 'refresh' ? request.previousSlot : selected;
    return { slot, home: `fixture/${slot}`, meter: 'codex', auth: { accessToken: `SECRET-${slot}`, chatgptAccountId: slot } };
  };
  const bridge = new CodexBridge({ ...options, broker, cwd: 'fixture', toClient: msg => client.push(msg), toNative: msg => {
    native.push(msg);
    if (String(msg.id).startsWith('hotpl8-internal-')) queueMicrotask(() => bridge.native({ id: msg.id, result: msg.method === 'config/read' ? { config } : {} }));
  }});
  return { bridge, native, client, requests, select: slot => { selected = slot; }, reject: () => { reject = true; }, config: c => { config = c; } };
}
async function opened(h) {
  await h.bridge.client({ id: 1, method: 'initialize', params: { clientInfo: { name: 'fixture' } } });
  await h.bridge.client({ method: 'initialized' });
  await h.bridge.client({ id: 2, method: 'thread/resume', params: { threadId: 't', model: 'fixture-model' } });
  h.bridge.native({ id: 2, result: { thread: { id: 't' } } });
}

test('explicit admission and background rollover carry distinct intents and process dwell', async () => {
  const h = harness();
  const broker = h.bridge.broker;
  const state = { active: true, selected: 'a', selectedAt: '2026-09-22T00:00:00Z' };
  h.bridge.broker = async request => ({ ...await broker(request), criticalState: state });
  await opened(h);
  assert.equal(h.requests[0].intent, 'admit');
  const confirmed = h.bridge.route.criticalState;
  assert.equal(confirmed.active, true);
  assert.equal(confirmed.selected, 'a');
  assert.notEqual(confirmed.selectedAt, state.selectedAt);
  h.bridge.native({ method: 'turn/started', params: { threadId: 't', turn: { id: 'turn' } } });
  await h.bridge.observe();
  assert.equal(h.requests.at(-1).intent, 'rebind');
  assert.deepEqual(h.requests.at(-1).criticalState, confirmed);
  assert.equal(h.bridge.route.criticalState.selectedAt, confirmed.selectedAt);
  assert.equal(h.requests.at(-1).previousSlot, 'a');
  h.bridge.close();
});

test('failed native apply invalidates the binding receipt without replaying work', async () => {
  const h = harness(); await opened(h);
  const send = h.bridge.toNative;
  h.bridge.toNative = message => {
    if (message.method === 'account/login/start') {
      h.native.push(message);
      queueMicrotask(() => h.bridge.native({ id: message.id, error: { message: 'fixture failure' } }));
    } else send(message);
  };
  const count = h.native.filter(m => m.method === 'turn/start').length;
  h.select('b'); await assert.rejects(h.bridge.select(), /routing_native_rejected/);
  assert.equal(h.bridge.route, null);
  assert.equal(h.native.filter(m => m.method === 'turn/start').length, count);
  assert.equal(h.bridge.active.size, 0);
  h.bridge.close();
});

test('initialization authenticates with ephemeral external tokens; no token reaches client', async () => {
  const h = harness(); await opened(h);
  assert.equal(h.bridge.initialized, true);
  assert.equal(h.native.filter(m => m.method === 'initialized').length, 1);
  assert.ok(h.native.some(m => m.method === 'account/login/start' && m.params.accessToken === 'SECRET-a'));
  assert.ok(!JSON.stringify(h.client).includes('SECRET'));
  h.bridge.close();
});
test('new and resumed turns route at admission while keeping thread identity', async () => {
  const h = harness(); await opened(h); h.select('b');
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't', model: 'other-model', input: [{ type: 'text', text: 'hello' }] } });
  assert.equal(h.bridge.route.slot, 'b');
  assert.equal('model' in h.requests.at(-1), false);
  assert.equal(h.native.at(-1).params.model, 'other-model');
  assert.equal(h.native.at(-1).params.threadId, 't');
  assert.deepEqual(h.native.at(-1).params.input, [{ type: 'text', text: 'hello' }]);
  h.bridge.close();
});
test('active follow-ups retain native input and response while approvals and steering flow', async () => {
  const h = harness(); await opened(h);
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't' } });
  h.bridge.native({ id: 3, result: { turn: { id: 'one' } } });
  h.bridge.native({ method: 'turn/started', params: { threadId: 't', turn: { id: 'one' } } });
  h.select('b'); const before = h.requests.length;
  const followup = { id: 4, method: 'turn/start', params: { threadId: 't', input: [{ type: 'text', text: 'continue' }, { type: 'image', url: 'fixture' }] } };
  await h.bridge.client(followup);
  assert.equal(h.requests.length, before); assert.deepEqual(h.native.at(-1), followup);
  h.bridge.native({ id: 4, result: { turn: { id: 'one' } } });
  assert.equal(h.client.at(-1).result.turn.id, 'one');
  h.bridge.native({ id: 991, method: 'item/commandExecution/requestApproval', params: { command: 'fixture' } });
  await h.bridge.client({ id: 991, result: { decision: 'accept' } });
  assert.equal(h.native.at(-1).id, 991);
  await h.bridge.client({ id: 5, method: 'turn/steer', params: { threadId: 't', input: [] } });
  assert.equal(h.native.at(-1).method, 'turn/steer'); h.bridge.close();
});
test('failed turns are forwarded once, never replayed; next turn can choose another account', async () => {
  const h = harness(); await opened(h);
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't' } });
  h.bridge.native({ id: 3, result: { turn: { id: 'turn' } } });
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't', turn: { status: 'failed', error: { codexErrorInfo: 'usageLimitExceeded' } } } });
  assert.equal(h.native.filter(m => m.method === 'turn/start').length, 1);
  h.select('b'); await h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 't' } });
  assert.equal(h.bridge.route.slot, 'b'); h.bridge.close();
});
test('ongoing child work defers account changes even after parent completion', async () => {
  const h = harness(); await opened(h);
  h.bridge.native({ method: 'thread/started', params: { thread: { id: 'child', model: 'fixture-model', cwd: 'fixture' } } });
  h.bridge.native({ method: 'turn/started', params: { threadId: 'child' } });
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't' } });
  h.select('b'); await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'a'); assert.equal(h.bridge.active.has('child'), true);
  assert.equal('models' in h.requests.at(-1), false);
  h.bridge.native({ method: 'turn/completed', params: { threadId: 'child' } });
  await h.bridge.select();
  assert.equal(h.bridge.route.slot, 'b'); h.bridge.close();
});
test('quota failure blocks inference with fixed error and no fallback to native shared auth', async () => {
  const h = harness(); await opened(h); h.reject();
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't' } });
  assert.match(h.client.at(-1).error.message, /routing_unavailable/);
  assert.equal(h.native.filter(m => m.method === 'turn/start').length, 0); h.bridge.close();
});
test('native rejected turn admission releases its reservation', async () => {
  const h = harness(); await opened(h);
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't' } });
  h.bridge.native({ id: 3, error: { code: 1, message: 'fixture' } });
  assert.equal(h.bridge.active.size, 0); h.bridge.close();
});
test('external refresh is pinned, private, and mismatched previousAccountId fails', async () => {
  const h = harness(); await opened(h); h.select('b');
  await h.bridge.refresh({ id: 9, params: { previousAccountId: 'a' } });
  assert.equal(h.native.at(-1).result.chatgptAccountId, 'a');
  assert.equal(h.requests.at(-1).operation, 'refresh');
  assert.ok(!JSON.stringify(h.client).includes('SECRET'));
  await h.bridge.refresh({ id: 10, params: { previousAccountId: 'b' } });
  assert.equal(h.native.at(-1).error.code, -32001); h.bridge.close();
});
test('all-account failure and malformed broker output never leak raw errors', async () => {
  const h = harness(); h.bridge.broker = async () => { throw new Error('SECRET-account'); };
  await h.bridge.client({ id: 1, method: 'initialize', params: {} });
  assert.match(h.client.at(-1).error.message, /routing_failed/);
  assert.ok(!JSON.stringify(h.client).includes('SECRET')); h.bridge.close();
});
test('mutating account/config operations and reserved IDs are rejected', async () => {
  const h = harness(); await opened(h);
  for (const method of ['account/logout', 'account/login/start', 'account/rateLimitResetCredit/consume', 'config/value/write', 'config/batchWrite']) {
    await h.bridge.client({ id: 20, method, params: {} }); assert.ok(h.client.at(-1).error);
  }
  await h.bridge.client({ id: 'hotpl8-internal-99', method: 'account/read' });
  assert.match(h.client.at(-1).error.message, /reserved/); h.bridge.close();
});
test('unknown threads and project transport overrides fail closed', async () => {
  const h = harness(); await opened(h);
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 'unknown' } });
  assert.match(h.client.at(-1).error.message, /thread_unknown/);
  h.config({ model_provider: 'other' });
  await h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 't' } });
  assert.match(h.client.at(-1).error.message, /config_conflict/); h.bridge.close();
});
test('command arguments cover T3 exec helpers and reject billing/home overrides', () => {
  assert.equal(validateArgs(['--ephemeral', '--skip-git-repo-check', '-s', 'read-only', '--model', 'fixture', '-c', 'model_reasoning_effort="low"', '--output-schema', 'C:/space x/a.json', '--output-last-message', 'out', '-'], true).model, 'fixture');
  for (const args of [['--listen', 'ws://0.0.0.0:1'], ['-c', 'model_provider="other"'], ['--config', 'cli_auth_credentials_store="file"'], ['--profile', 'api'], ['--remote', 'ws://fixture']]) assert.throws(() => validateArgs(args));
  assert.throws(() => assertEnvironment({ OPENAI_API_KEY: 'fixture' }));
  assert.throws(() => assertConfig({ model_providers: { openai: { base_url: 'https://fixture.invalid' } } }));
});
test('framing preserves Unicode across chunks and handles EOF/malformed input', () => {
  const stream = new PassThrough(), values = [], failures = [];
  readLines(stream, msg => values.push(msg), err => failures.push(err.code));
  const line = Buffer.from('{"text":"\u732b"}\n'); stream.write(line.subarray(0, 10)); stream.write(line.subarray(10));
  assert.equal(values[0].text, '\u732b'); stream.write('not-json\n');
  assert.deepEqual(failures, ['routing_invalid_frame']); stream.destroy();
});
test('native request timeout is bounded and redacted', async () => {
  const bridge = new CodexBridge({ broker: async () => {}, toNative: () => {}, toClient: () => {}, timeoutMs: 10 });
  await assert.rejects(bridge.rpc('initialize', {}), /routing_native_timeout/); bridge.close();
});
test('explicit compaction receives quota admission and owns only its reservation', async () => {
  const h = harness(); await opened(h); h.select('b');
  await h.bridge.client({ id: 7, method: 'thread/compact/start', params: { threadId: 't' } });
  assert.equal(h.bridge.route.slot, 'b'); assert.equal(h.bridge.reservations.get('7'), 't');
  assert.deepEqual(h.native.at(-1).params, { threadId: 't' });
  h.bridge.native({ id: 7, error: { code: 1 } }); assert.equal(h.bridge.reservations.size, 0);
  h.bridge.close();
});
test('T3 MCP launch arguments preserve its callback and environment reference', () => {
  assert.doesNotThrow(() => validateArgs(['-c', 'mcp_servers.t3-code.url=http://127.0.0.1:1234/mcp', '-c', 'mcp_servers.t3-code.bearer_token_env_var="T3_MCP_BEARER_TOKEN"']));
});
test('editing a managed provider home cannot silently resume a different conversation store', () => {
  assert.doesNotThrow(() => assertSharedHome('fixture/shared', 'fixture/shared/'));
  assert.throws(() => assertSharedHome('fixture/shared', 'fixture/another'), /routing_home_conflict/);
});

function started(h, threadId = 't', id = 'one') {
  h.bridge.native({ method: 'turn/started', params: { threadId, turn: { id } } });
}

test('live native network permissions survive a preferred-account change', async () => {
  const h = harness(); await opened(h); started(h);
  const send = h.bridge.toNative;
  h.bridge.toNative = message => {
    if (message.method === 'account/login/start' && h.bridge.active.size) {
      h.bridge.native({ method: 'error', params: { threadId: 't', error: { message: 'application network permission was revoked' } } });
    }
    send(message);
  };
  h.select('b'); await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'a');
  assert.equal(h.native.filter(m => m.method === 'account/login/start').length, 1);
  assert.ok(!h.client.some(m => m.method === 'error'));
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't', turn: { id: 'one' } } });
  await h.bridge.client({ id: 41, method: 'turn/start', params: { threadId: 't' } });
  assert.equal(h.bridge.route.slot, 'b');
  assert.equal(h.native.filter(m => m.method === 'turn/start').length, 1);
  h.bridge.close();
});

test('pending admission and newly active children prevent a concurrent account change', async () => {
  const h = harness(); await opened(h);
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't' } });
  h.select('b'); await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'a');
  h.bridge.threads.set('other', { model: 'fixture-model', cwd: 'fixture' });
  await h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 'other' } });
  assert.match(h.client.at(-1).error.message, /routing_account_change_deferred/);
  assert.equal(h.native.filter(m => m.method === 'turn/start').length, 1);
  h.bridge.native({ id: 3, error: { code: 1 } });
  const broker = h.bridge.broker;
  h.bridge.broker = async request => { started(h, 'other'); return broker(request); };
  await h.bridge.client({ id: 5, method: 'turn/start', params: { threadId: 't' } });
  assert.match(h.client.at(-1).error.message, /routing_account_change_deferred/);
  assert.equal(h.native.filter(m => m.method === 'account/login/start').length, 1);
  h.bridge.close();
});

test('quota observation preserves the account of ongoing work without resubmitting a turn', async () => {
  const h = harness(); await opened(h); started(h);
  h.select('b'); await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'a');
  assert.equal(h.bridge.active.get('t'), 'one');
  assert.equal(h.native.filter(m => m.method === 'turn/start').length, 0);
  const logins = h.native.filter(m => m.method === 'account/login/start').length;
  await h.bridge.observe();
  assert.equal(h.native.filter(m => m.method === 'account/login/start').length, logins);
  assert.ok(!JSON.stringify(h.client).includes('SECRET')); h.bridge.close();
});

test('slow rollover does not block follow-ups, approvals, steering or interruption', async () => {
  const h = harness(); await opened(h); started(h);
  const broker = h.bridge.broker; let release;
  h.bridge.broker = async request => { await new Promise(done => { release = done; }); return broker(request); };
  h.select('b'); const observing = h.bridge.observe(); await new Promise(done => setImmediate(done));
  for (const msg of [{ id: 8, result: {} }, { id: 9, method: 'turn/steer', params: { threadId: 't' } },
    { id: 10, method: 'turn/start', params: { threadId: 't' } }, { id: 11, method: 'turn/interrupt', params: { threadId: 't' } }]) {
    await h.bridge.client(msg); assert.deepEqual(h.native.at(-1), msg);
  }
  assert.equal(h.bridge.route.slot, 'a'); release(); await observing;
  assert.equal(h.bridge.route.slot, 'a'); h.bridge.close();
});

test('a rejected follow-up and late completion cannot clear a different active turn', async () => {
  const h = harness(); await opened(h); started(h);
  await h.bridge.client({ id: 10, method: 'turn/start', params: { threadId: 't' } });
  h.bridge.native({ id: 10, error: { code: 1 } });
  assert.equal(h.bridge.active.get('t'), 'one');
  started(h, 't', 'two');
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't', turn: { id: 'one' } } });
  h.bridge.native({ method: 'thread/status/changed', params: { threadId: 't', status: { type: 'idle' } } });
  assert.equal(h.bridge.active.get('t'), 'two');
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't', turn: { id: 'two' } } });
  assert.equal(h.bridge.active.size, 0); h.bridge.close();
});

test('unavailable rollover leaves native work intact and reports a fixed diagnostic', async () => {
  const h = harness(); await opened(h); started(h); h.reject();
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  await h.bridge.observe();
  assert.deepEqual(errors, ['routing_unavailable']); assert.equal(h.bridge.route.slot, 'a');
  assert.equal(h.native.filter(m => m.method === 'turn/interrupt').length, 0);
  await h.bridge.client({ id: 10, method: 'turn/start', params: { threadId: 't' } });
  assert.equal(h.native.at(-1).id, 10); h.bridge.close();
});

test('observation bursts coalesce, and shutdown prevents late authentication', async () => {
  const h = harness(); await opened(h); started(h); h.select('b');
  const broker = h.bridge.broker; let release;
  h.bridge.broker = async request => { await new Promise(done => { release = done; }); return broker(request); };
  const before = h.native.length;
  const first = h.bridge.observe(); await new Promise(done => setImmediate(done));
  for (let n = 0; n < 50; n++) assert.equal(h.bridge.observe(), first);
  h.bridge.close(); release(); await first;
  assert.equal(h.native.length, before); assert.equal(h.bridge.route, null);
});

// A background validation that never answers on its own, as when its native read is
// slow or it is waiting on a held account lock. It ends only when it is stopped.
function stalled(h) {
  const broker = h.bridge.broker, seen = { stopped: 0 };
  h.bridge.broker = (request, signal) => request.intent !== 'rebind' ? broker(request) : new Promise((_, reject) => {
    h.requests.push(request);
    signal.addEventListener('abort', () => { seen.stopped++; reject(Object.assign(new Error(), { code: 'routing_cancelled' })); });
  });
  return seen;
}

test('an admission does not wait behind a background validation, running or queued', async () => {
  const h = harness(); await opened(h); started(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  const seen = stalled(h);
  const observing = h.bridge.observe(); await new Promise(done => setImmediate(done));
  assert.equal(h.requests.at(-1).intent, 'rebind');
  assert.equal((await h.bridge.select()).slot, 'a');
  assert.equal(seen.stopped, 1); assert.equal(h.requests.at(-1).intent, 'admit');
  await observing; assert.deepEqual(errors, []); assert.equal(h.bridge.route.slot, 'a');
  let release; h.bridge.routing = new Promise(done => { release = done; });
  const before = h.requests.length;
  const queued = h.bridge.observe(), admission = h.bridge.select();
  release(); await Promise.all([queued, admission]);
  assert.deepEqual(h.requests.slice(before).map(request => request.intent), ['admit']);
  assert.deepEqual(errors, []); h.bridge.close();
});

test('a background validation that finds the account lock held is skipped without a diagnostic', async () => {
  const h = harness(); await opened(h); started(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  const broker = h.bridge.broker;
  h.bridge.broker = async request => { throw Object.assign(new Error(), { code: 'routing_account_busy' }); };
  await h.bridge.observe();
  assert.deepEqual(errors, []); assert.equal(h.bridge.route.slot, 'a');
  // The same answer to an admission is a failure someone is waiting on.
  await assert.rejects(h.bridge.select(), { code: 'routing_account_busy' });
  h.bridge.broker = broker; h.bridge.close();
});

test('native quota notifications share one validation per interval and all reach the client', async () => {
  const h = harness({ quotaIntervalMs: 300 }); await opened(h); started(h);
  const before = h.requests.length;
  for (let n = 0; n < 20; n++) h.bridge.native({ method: 'account/rateLimits/updated', params: { n } });
  await new Promise(done => setImmediate(done));
  assert.equal(h.requests.length, before);
  await new Promise(done => setTimeout(done, 450));
  assert.equal(h.requests.length, before + 1); assert.equal(h.requests.at(-1).intent, 'rebind');
  assert.equal(h.client.filter(m => m.method === 'account/rateLimits/updated').length, 20);
  // An interval with no validation in it: the next notification validates at once.
  await new Promise(done => setTimeout(done, 350));
  h.bridge.native({ method: 'account/rateLimits/updated', params: {} });
  await new Promise(done => setImmediate(done));
  assert.equal(h.requests.length, before + 2);
  // Collector publications are not held back.
  await h.bridge.observe();
  assert.equal(h.requests.length, before + 3); h.bridge.close();
});

test('closing the bridge stops a validation in flight and any held-back wakeup', async () => {
  const h = harness({ quotaIntervalMs: 50 }); await opened(h); started(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  const seen = stalled(h);
  const observing = h.bridge.observe(); await new Promise(done => setImmediate(done));
  h.bridge.native({ method: 'account/rateLimits/updated', params: {} });
  const before = h.requests.length;
  h.bridge.close(); await observing;
  assert.equal(seen.stopped, 1); assert.deepEqual(errors, []);
  await new Promise(done => setTimeout(done, 120));
  assert.equal(h.requests.length, before);
});

test('active sibling models do not affect account selection or permit rebinding', async () => {
  const h = harness(); await opened(h); started(h);
  h.bridge.threads.set('sibling', { model: 'other-model', cwd: 'fixture' }); started(h, 'sibling');
  h.select('b'); await h.bridge.observe();
  assert.equal('models' in h.requests.at(-1), false); assert.equal(h.bridge.route.slot, 'a'); h.bridge.close();
});

test('the native first-party base URL cannot redirect subscription auth', () => {
  assert.throws(() => assertConfig({ openai_base_url: 'https://fixture.invalid' }), /routing_config_conflict/);
});

test('unknown child metadata and new children retain the active account without model discovery', async () => {
  const h = harness(); await opened(h); started(h, 'unknown-child'); h.select('b');
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  await h.bridge.observe();
  assert.deepEqual(errors, []); assert.equal(h.native.some(m => m.method === 'thread/read'), false); assert.equal(h.bridge.route.slot, 'a');
  h.bridge.active.clear(); started(h);
  const broker = h.bridge.broker;
  h.bridge.broker = async request => {
    h.bridge.threads.set('new-child', { model: 'different-model', cwd: 'fixture' }); started(h, 'new-child');
    return broker(request);
  };
  await h.bridge.observe();
  assert.deepEqual(errors, []); assert.equal(h.native.filter(m => m.method === 'account/login/start').length, 1); assert.equal(h.bridge.route.slot, 'a'); h.bridge.close();
});

test('rejected model changes preserve the native active model and reservation ownership', async () => {
  const h = harness(); await opened(h); started(h);
  await h.bridge.client({ id: 7, method: 'turn/start', params: { threadId: 't', model: 'different-model' } });
  await h.bridge.observe();
  assert.equal('models' in h.requests.at(-1), false);
  assert.equal(h.native.find(m => m.id === 7).params.model, 'different-model');
  h.bridge.native({ id: 7, error: { code: 1 } });
  assert.equal(h.bridge.threads.get('t').model, 'fixture-model');
  assert.equal(h.bridge.active.get('t'), 'one'); assert.equal(h.bridge.reservations.size, 0); h.bridge.close();
});

test('late refresh cannot restore the account replaced by a rollover', async () => {
  const h = harness(); await opened(h);
  const broker = h.bridge.broker; let release;
  h.bridge.broker = async request => {
    if (request.operation === 'refresh') await new Promise(done => { release = done; });
    return broker(request);
  };
  const refresh = h.bridge.refresh({ id: 91, params: { previousAccountId: 'a' } });
  h.select('b'); await h.bridge.select(); release(); await refresh;
  assert.equal(h.bridge.route.slot, 'b'); assert.match(h.native.at(-1).error.message, /routing_refresh_failed/); h.bridge.close();
});

test('completed child model cannot affect account selection for surviving work', async () => {
  const h = harness(); await opened(h); started(h);
  h.bridge.threads.set('finishing', { model: 'finished-model', cwd: 'fixture' });
  await h.bridge.client({ id: 7, method: 'turn/start', params: { threadId: 'finishing' } });
  h.bridge.native({ id: 7, result: { turn: { id: 'done' } } }); started(h, 'finishing', 'done');
  assert.equal('model' in h.bridge.route, false);
  h.bridge.native({ method: 'turn/completed', params: { threadId: 'finishing', turn: { id: 'done' } } });
  const broker = h.bridge.broker;
  h.bridge.broker = request => {
    assert.equal('model' in request, false); assert.equal('models' in request, false);
    return broker(request);
  };
  await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'a'); assert.equal(h.bridge.active.get('t'), 'one');
  assert.equal('models' in h.requests.at(-1), false); h.bridge.close();
});

test('queued observation retains active ownership and ignores completed work', async () => {
  const h = harness(); await opened(h); started(h);
  h.bridge.threads.set('finishing', { model: 'finished-model', cwd: 'fixture' }); started(h, 'finishing', 'done');
  let release;
  h.bridge.routing = new Promise(done => { release = done; });
  const observation = h.bridge.observe();
  h.bridge.native({ method: 'turn/completed', params: { threadId: 'finishing', turn: { id: 'done' } } });
  h.select('b'); release(); await observation;
  assert.equal(h.bridge.route.slot, 'a'); assert.equal('models' in h.requests.at(-1), false);
  const before = h.requests.length;
  h.bridge.routing = new Promise(done => { release = done; });
  const idleObservation = h.bridge.observe();
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't', turn: { id: 'one' } } });
  release(); await idleObservation;
  assert.equal(h.requests.length, before); h.bridge.close();
});

test('initialization still admits the native default when configuration omits model', async () => {
  const h = harness(); h.config({ cli_auth_credentials_store: 'ephemeral' }); await opened(h);
  assert.equal(h.bridge.route.slot, 'a');
  assert.equal(h.native.filter(m => m.method === 'account/login/start').length, 1); h.bridge.close();
});

test('unseen models and native options pass through unchanged and failures are never replayed', async () => {
  const h = harness(); await opened(h);
  const variants = [{}, { model: null }, ...Array.from({ length: 200 }, (_, n) => ({
    model: `future-family-${n}`, serviceTier: n % 2 ? 'priority' : null, effort: 'high'
  }))];
  try {
    for (const [index, options] of variants.entries()) {
      const message = { id: index + 100, method: 'turn/start', params: { threadId: 't', input: [], ...options } };
      await h.bridge.client(message);
      assert.deepEqual(h.native.at(-1), message);
      assert.equal('model' in h.requests.at(-1), false);
      assert.equal('models' in h.requests.at(-1), false);
      const failure = { id: message.id, error: { code: -32602, message: 'Synthetic native model unavailable' } };
      h.bridge.native(failure);
      assert.deepEqual(h.client.at(-1), failure);
      assert.equal(h.native.filter(m => m.id === message.id).length, 1);
    }
    assert.equal(h.bridge.reservations.size, 0);
  } finally { h.bridge.close(); }
});

test('native model rerouting is forwarded without a new account decision', async () => {
  const h = harness(); await opened(h); started(h);
  const before = h.requests.length;
  const notification = { method: 'model/rerouted', params: { threadId: 't', turnId: 'one', toModel: 'future-native-fallback' } };
  h.bridge.native(notification);
  await new Promise(done => setImmediate(done));
  assert.deepEqual(h.client.at(-1), notification);
  assert.equal(h.requests.length, before);
  assert.equal(h.bridge.route.slot, 'a');
  assert.equal(h.bridge.active.get('t'), 'one'); h.bridge.close();
});

// Automatic continue: the waiter is a fake, so these drive only the bridge's own rules.
function waiting(h) {
  const calls = [];
  h.bridge.waiter = (threadId, slot, after, held) => {
    const call = { threadId, slot, after, held, killed: false, kill: () => { call.killed = true; } };
    call.done = new Promise(done => { call.finish = done; });
    calls.push(call); return call;
  };
  return calls;
}
const limited = (h, threadId = 't') => ({ method: 'turn/completed', params: { threadId, turn: { status: 'failed', error: { codexErrorInfo: 'usageLimitExceeded' } } } });
const turns = h => h.native.filter(m => m.method === 'turn/start');
async function finished(h, call, code) {
  call.finish(code); await new Promise(done => setImmediate(done)); await h.bridge.serial;
}
async function limitedTurn(h) {
  const calls = waiting(h);
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't', input: [{ type: 'text', text: 'original' }] } });
  h.bridge.native({ id: 3, result: { turn: { id: 'turn' } } });
  h.bridge.native(limited(h));
  return calls;
}

test('a usage-limit failure is continued once, as a new turn on the newly selected account', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  assert.deepEqual(h.client.at(-1), limited(h));
  assert.deepEqual(calls.map(c => [c.threadId, c.slot, c.held]), [['t', 'a', false]]);
  assert.ok(Math.abs(Date.now() - Date.parse(calls[0].after)) < 60000);
  const before = h.client.length;
  h.select('b'); await finished(h, calls[0], 2);
  assert.equal(turns(h).length, 2);
  assert.match(turns(h)[1].id, /^hotpl8-internal-/);
  assert.deepEqual(turns(h)[1].params, { threadId: 't', input: [{ type: 'text', text: 'Automated message: continue.', text_elements: [] }] });
  assert.equal(h.bridge.route.slot, 'b');
  assert.equal(h.bridge.reservations.size, 0); assert.equal(h.bridge.waiters.size, 0);
  assert.equal(h.client.length, before);
  h.bridge.close();
});

test('a waiter that stands down, another failure or an untracked thread sends nothing', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  await finished(h, calls[0], 0);
  assert.equal(turns(h).length, 1); assert.equal(h.bridge.waiters.size, 0);
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't', turn: { status: 'failed', error: { codexErrorInfo: 'other' } } } });
  h.bridge.native(limited(h, 'unknown'));
  assert.equal(calls.length, 1); h.bridge.close();
});

test('the owner writing first cancels the waiter and no continue follows', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  await h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 't', input: [{ type: 'text', text: 'mine' }] } });
  assert.equal(calls[0].killed, true);
  await finished(h, calls[0], 2);
  assert.deepEqual(turns(h).map(m => m.id), [3, 4]); h.bridge.close();
});

test('a continue is never sent into running work', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  started(h); await finished(h, calls[0], 2);
  assert.equal(turns(h).length, 1); assert.equal(h.bridge.waiters.size, 0); h.bridge.close();
});

test('a continue that cannot be admitted is dropped with one fixed diagnostic', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  const before = h.client.length;
  h.reject(); await finished(h, calls[0], 2);
  assert.deepEqual(errors, ['routing_continue_failed']);
  assert.equal(turns(h).length, 1); assert.equal(h.bridge.reservations.size, 0); assert.equal(h.bridge.waiters.size, 0);
  assert.equal(h.client.length, before); assert.equal(calls.length, 1); h.bridge.close();
});

test('closing the bridge ends every waiter', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  h.bridge.close();
  assert.equal(calls[0].killed, true);
  await finished(h, calls[0], 2);
  assert.equal(turns(h).length, 1);
});

// Sub-agents share the conversation's process and account, so they can outlive its limit failure.
function child(h, threadId = 'child', id = 'c1') {
  h.bridge.native({ method: 'thread/started', params: { thread: { id: threadId, model: 'fixture-model', cwd: 'fixture' } } });
  started(h, threadId, id);
}
const ended = (threadId = 'child', id = 'c1') => ({ method: 'turn/completed', params: { threadId, turn: { id, status: 'completed' } } });
const continues = h => turns(h).filter(m => String(m.id).startsWith('hotpl8-internal-'));
const logins = h => h.native.filter(m => m.method === 'account/login/start').length;
// The waiter says continue while one sub-agent still runs on the account that must be left.
async function held(h) {
  const calls = await limitedTurn(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  child(h); h.select('b');
  await finished(h, calls[0], 2);
  assert.equal(h.bridge.waiters.get('t').held, true);
  assert.equal(continues(h).length, 0); assert.deepEqual(errors, []);
  return { calls, errors };
}
// The sub-agent ends, so the waiter is started again for the same failure.
async function asked(h, calls, threadId = 'child', id = 'c1') {
  const before = calls.length;
  h.bridge.native(ended(threadId, id)); await h.bridge.serial;
  assert.equal(calls.length, before + 1);
  const call = calls.at(-1);
  assert.deepEqual([call.threadId, call.slot, call.after, call.held], ['t', 'a', calls[0].after, true]);
  assert.equal(continues(h).length, 0); assert.equal(h.bridge.route.slot, 'a');
  return call;
}

test('a continue that needs another account waits for running sub-agents, then is sent once', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  // Both sub-agents die on the same limit after the conversation did.
  child(h); child(h, 'child2', 'c2');
  const before = logins(h);
  h.select('b'); await finished(h, calls[0], 2);
  assert.equal(continues(h).length, 0); assert.equal(h.bridge.route.slot, 'a');
  assert.deepEqual(errors, []); assert.equal(calls[0].killed, false);
  h.bridge.native({ method: 'turn/completed', params: { threadId: 'child', turn: { id: 'c1', status: 'failed', error: { codexErrorInfo: 'usageLimitExceeded' } } } });
  await h.bridge.serial;
  assert.equal(calls.filter(c => c.held).length, 0);
  assert.equal(continues(h).length, 0); assert.equal(h.bridge.route.slot, 'a'); assert.equal(logins(h), before);
  h.bridge.native({ method: 'turn/completed', params: { threadId: 'child2', turn: { id: 'c2', status: 'failed', error: { codexErrorInfo: 'usageLimitExceeded' } } } });
  await h.bridge.serial;
  // The waiter is asked again for the same failure; nothing is sent on its first answer.
  const again = calls.filter(c => c.held);
  assert.deepEqual(again.map(c => [c.threadId, c.slot, c.after]), [['t', 'a', calls[0].after]]);
  assert.equal(continues(h).length, 0); assert.equal(h.bridge.route.slot, 'a'); assert.equal(logins(h), before);
  await finished(h, again[0], 2);
  assert.deepEqual(continues(h).map(m => m.params), [{ threadId: 't', input: [{ type: 'text', text: 'Automated message: continue.', text_elements: [] }] }]);
  assert.equal(h.bridge.route.slot, 'b'); assert.equal(logins(h), before + 1);
  assert.equal(h.bridge.waiters.has('t'), false); assert.equal(h.bridge.reservations.size, 0);
  assert.deepEqual(errors, []);
  // Later traffic finds nothing held: the waiter is not asked and the continue is not sent again.
  h.bridge.native({ method: 'thread/status/changed', params: { threadId: 'child', status: { type: 'idle' } } });
  await h.bridge.serial;
  assert.equal(calls.filter(c => c.held).length, 1); assert.equal(continues(h).length, 1); h.bridge.close();
});

test('a continue on the account already in use is sent while sub-agents run', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  child(h); await finished(h, calls[0], 2);
  assert.equal(continues(h).length, 1); assert.equal(h.bridge.route.slot, 'a');
  assert.equal(h.bridge.waiters.size, 0); h.bridge.close();
});

test('a held continue is not sent when the waiter stands down the second time', async () => {
  const h = harness(); await opened(h);
  const { calls, errors } = await held(h);
  const before = logins(h);
  await finished(h, await asked(h, calls), 0);
  assert.equal(continues(h).length, 0); assert.equal(h.bridge.waiters.size, 0);
  assert.equal(h.bridge.route.slot, 'a'); assert.equal(logins(h), before); assert.deepEqual(errors, []);
  // Nothing is left of it: later traffic does not ask the waiter a third time.
  h.bridge.native({ method: 'thread/status/changed', params: { threadId: 'child', status: { type: 'idle' } } });
  await h.bridge.serial;
  assert.equal(calls.length, 2); h.bridge.close();
});

test('a continue held a second time is sent once', async () => {
  const h = harness(); await opened(h);
  const { calls, errors } = await held(h);
  const second = await asked(h, calls);
  // Another sub-agent starts while the account for the continue is validated.
  const broker = h.bridge.broker;
  h.bridge.broker = async request => { h.bridge.broker = broker; child(h, 'child2', 'c2'); return broker(request); };
  await finished(h, second, 2);
  assert.equal(h.bridge.waiters.get('t').held, true);
  assert.equal(continues(h).length, 0); assert.equal(h.bridge.route.slot, 'a'); assert.deepEqual(errors, []);
  await finished(h, await asked(h, calls, 'child2', 'c2'), 2);
  assert.equal(continues(h).length, 1); assert.equal(h.bridge.route.slot, 'b');
  assert.equal(calls.length, 3); assert.equal(h.bridge.waiters.size, 0); assert.deepEqual(errors, []); h.bridge.close();
});

test('the owner writing while a continue is held cancels it', async () => {
  const h = harness(); await opened(h);
  const { calls, errors } = await held(h);
  await h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 't', input: [{ type: 'text', text: 'mine' }] } });
  assert.equal(calls[0].killed, true); assert.equal(h.bridge.waiters.size, 0);
  // Their own message meets the same rule: the account cannot change under the sub-agent.
  assert.match(h.client.at(-1).error.message, /routing_account_change_deferred/);
  assert.deepEqual(turns(h).map(m => m.id), [3]);
  h.bridge.native(ended()); await h.bridge.serial;
  assert.equal(calls.length, 1); assert.equal(continues(h).length, 0); assert.deepEqual(errors, []); h.bridge.close();
});

test('the owner writing while the waiter is asked again cancels the held continue', async () => {
  const h = harness(); await opened(h);
  const { calls, errors } = await held(h);
  const second = await asked(h, calls);
  await h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 't', input: [{ type: 'text', text: 'mine' }] } });
  assert.equal(second.killed, true); assert.equal(h.bridge.waiters.size, 0);
  await finished(h, second, 2);
  assert.deepEqual(turns(h).map(m => m.id), [3, 4]); assert.deepEqual(errors, []); h.bridge.close();
});

test('closing the bridge ends a held continue', async () => {
  const h = harness(); await opened(h);
  const { calls, errors } = await held(h);
  h.bridge.close();
  h.bridge.native(ended()); await h.bridge.serial;
  assert.equal(calls.length, 1); assert.equal(continues(h).length, 0);
  assert.equal(h.bridge.waiters.size, 0); assert.deepEqual(errors, []);
});

test('a repeated limit failure does not replace a held continue', async () => {
  const h = harness(); await opened(h);
  const { calls } = await held(h);
  h.bridge.native(limited(h));
  assert.equal(calls.length, 1); assert.equal(calls[0].killed, false);
  assert.equal(h.bridge.waiters.get('t').held, true);
  const second = await asked(h, calls);
  h.bridge.native(limited(h));
  assert.equal(calls.length, 2); assert.equal(second.killed, false);
  await finished(h, second, 2);
  assert.equal(continues(h).length, 1); assert.equal(h.bridge.waiters.size, 0);
  // Once it is sent, a new failure is an ordinary one again.
  h.bridge.native(limited(h));
  assert.deepEqual([calls.length, calls[2].held], [3, false]); h.bridge.close();
});

// The conversation's limit failure is reported once more while its continue is being admitted.
function repeated(h) {
  const send = h.bridge.toNative, seen = { count: 0 };
  h.bridge.toNative = message => {
    if (message.method === 'config/read' && !seen.count++) h.bridge.native(limited(h));
    send(message);
  };
  return seen;
}

test('a repeated limit failure while the continue is admitted does not cancel it', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  const seen = repeated(h);
  h.select('b'); await finished(h, calls[0], 2);
  assert.ok(seen.count); assert.equal(calls.length, 1); assert.equal(continues(h).length, 1);
  assert.equal(h.bridge.route.slot, 'b'); assert.equal(h.bridge.waiters.size, 0); assert.deepEqual(errors, []);
  h.bridge.close();
});

test('a repeated limit failure while the continue is admitted does not keep it from being held', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  const seen = repeated(h);
  child(h); h.select('b'); await finished(h, calls[0], 2);
  assert.ok(seen.count); assert.equal(calls.length, 1);
  assert.equal(h.bridge.waiters.get('t').held, true); assert.equal(continues(h).length, 0);
  await finished(h, await asked(h, calls), 2);
  assert.equal(continues(h).length, 1); assert.equal(h.bridge.route.slot, 'b');
  assert.equal(h.bridge.waiters.size, 0); assert.deepEqual(errors, []); h.bridge.close();
});

test('a held continue that still cannot be admitted is dropped with one fixed diagnostic', async () => {
  const h = harness(); await opened(h);
  const { calls, errors } = await held(h);
  const second = await asked(h, calls);
  h.reject(); await finished(h, second, 2);
  assert.deepEqual(errors, ['routing_continue_failed']);
  assert.equal(continues(h).length, 0); assert.equal(h.bridge.waiters.size, 0);
  assert.equal(h.bridge.reservations.size, 0); h.bridge.close();
});

test('the owner writing while a continue is admitted sends only their message', async () => {
  const h = harness(); await opened(h);
  const calls = await limitedTurn(h);
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  const broker = h.bridge.broker; let owner;
  h.bridge.broker = async request => {
    owner ??= h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 't', input: [{ type: 'text', text: 'mine' }] } });
    return broker(request);
  };
  await finished(h, calls[0], 2); await owner;
  assert.deepEqual(turns(h).map(m => m.id), [3, 4]);
  assert.equal(h.bridge.waiters.size, 0); assert.deepEqual(errors, []); h.bridge.close();
});
