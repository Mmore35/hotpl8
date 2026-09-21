import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { CodexBridge, validateArgs, assertConfig, assertEnvironment, assertSharedHome, readLines } from '../src/t3-codex.mjs';

function harness() {
  const native = [], client = [], requests = [];
  let selected = 'a', reject = false, config = { model: 'fixture-model', cli_auth_credentials_store: 'ephemeral' };
  const broker = async request => {
    requests.push(request);
    if (reject) throw Object.assign(new Error(), { code: 'routing_unavailable' });
    const slot = request.operation === 'refresh' ? request.previousSlot : selected;
    return { slot, home: `fixture/${slot}`, model: request.model || 'fixture-model', meter: 'codex', auth: { accessToken: `SECRET-${slot}`, chatgptAccountId: slot } };
  };
  const bridge = new CodexBridge({ broker, cwd: 'fixture', toClient: msg => client.push(msg), toNative: msg => {
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
  assert.equal(h.requests.at(-1).model, 'other-model');
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
test('ongoing child work can adopt another account after parent completion', async () => {
  const h = harness(); await opened(h);
  h.bridge.native({ method: 'thread/started', params: { thread: { id: 'child', model: 'fixture-model', cwd: 'fixture' } } });
  h.bridge.native({ method: 'turn/started', params: { threadId: 'child' } });
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't' } });
  h.select('b'); await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'b'); assert.equal(h.bridge.active.has('child'), true);
  assert.deepEqual(h.requests.at(-1).models, ['fixture-model']); h.bridge.close();
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

test('quota observation switches ongoing work once, without resubmitting a turn', async () => {
  const h = harness(); await opened(h); started(h);
  h.select('b'); await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'b');
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
  assert.equal(h.bridge.route.slot, 'b'); h.bridge.close();
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

test('an account selection must include models in other active threads', async () => {
  const h = harness(); await opened(h); started(h);
  h.bridge.threads.set('sibling', { model: 'other-model', cwd: 'fixture' }); started(h, 'sibling');
  h.select('b'); await h.bridge.observe();
  assert.deepEqual(h.requests.at(-1).models, ['fixture-model', 'other-model']); h.bridge.close();
});

test('the native first-party base URL cannot redirect subscription auth', () => {
  assert.throws(() => assertConfig({ openai_base_url: 'https://fixture.invalid' }), /routing_config_conflict/);
});

test('unknown child metadata and model changes during validation defer auth safely', async () => {
  const h = harness(); await opened(h); started(h, 'unknown-child'); h.select('b');
  const errors = []; h.bridge.onRoutingError = code => errors.push(code);
  await h.bridge.observe();
  assert.deepEqual(errors, ['routing_model_unknown']); assert.equal(h.bridge.route.slot, 'a');
  h.bridge.active.clear(); started(h);
  const broker = h.bridge.broker;
  h.bridge.broker = async request => {
    h.bridge.threads.set('new-child', { model: 'different-model', cwd: 'fixture' }); started(h, 'new-child');
    return broker(request);
  };
  await h.bridge.observe();
  assert.equal(errors.at(-1), 'routing_model_changed'); assert.equal(h.bridge.route.slot, 'a'); h.bridge.close();
});

test('rejected model changes preserve the native active model and reservation ownership', async () => {
  const h = harness(); await opened(h); started(h);
  await h.bridge.client({ id: 7, method: 'turn/start', params: { threadId: 't', model: 'different-model' } });
  await h.bridge.observe();
  assert.deepEqual(new Set(h.requests.at(-1).models), new Set(['fixture-model', 'different-model']));
  h.bridge.native({ id: 7, error: { code: 1 } });
  assert.equal(h.bridge.threads.get('t').model, 'fixture-model');
  assert.equal(h.bridge.active.get('t'), 'one'); assert.equal(h.bridge.reservations.size, 0); h.bridge.close();
});

test('late refresh cannot restore the account replaced by a rollover', async () => {
  const h = harness(); await opened(h); started(h);
  const broker = h.bridge.broker; let release;
  h.bridge.broker = async request => {
    if (request.operation === 'refresh') await new Promise(done => { release = done; });
    return broker(request);
  };
  const refresh = h.bridge.refresh({ id: 91, params: { previousAccountId: 'a' } });
  h.select('b'); await h.bridge.observe(); release(); await refresh;
  assert.equal(h.bridge.route.slot, 'b'); assert.match(h.native.at(-1).error.message, /routing_refresh_failed/); h.bridge.close();
});

test('completed latest-admitted model cannot block surviving work on another meter', async () => {
  const h = harness(); await opened(h); started(h);
  h.bridge.threads.set('finishing', { model: 'finished-model', cwd: 'fixture' });
  await h.bridge.client({ id: 7, method: 'turn/start', params: { threadId: 'finishing' } });
  h.bridge.native({ id: 7, result: { turn: { id: 'done' } } }); started(h, 'finishing', 'done');
  assert.equal(h.bridge.route.model, 'finished-model');
  h.bridge.native({ method: 'turn/completed', params: { threadId: 'finishing', turn: { id: 'done' } } });
  const broker = h.bridge.broker;
  const meters = { 'fixture-model': 'codex', 'finished-model': 'codex_bengalfox' };
  h.bridge.broker = request => {
    if (request.models.some(model => meters[model] === 'codex_bengalfox')) throw Object.assign(new Error(), { code: 'routing_unavailable' });
    return broker(request);
  };
  h.select('b'); await h.bridge.observe();
  assert.equal(h.bridge.route.slot, 'b'); assert.equal(h.bridge.route.model, 'fixture-model');
  assert.deepEqual(h.requests.at(-1).models, ['fixture-model']); h.bridge.close();
});

test('queued observation derives its models when execution starts and ignores completed work', async () => {
  const h = harness(); await opened(h); started(h);
  h.bridge.threads.set('finishing', { model: 'finished-model', cwd: 'fixture' }); started(h, 'finishing', 'done');
  let release;
  h.bridge.routing = new Promise(done => { release = done; });
  const observation = h.bridge.observe();
  h.bridge.native({ method: 'turn/completed', params: { threadId: 'finishing', turn: { id: 'done' } } });
  h.select('b'); release(); await observation;
  assert.equal(h.bridge.route.slot, 'b'); assert.deepEqual(h.requests.at(-1).models, ['fixture-model']);
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
