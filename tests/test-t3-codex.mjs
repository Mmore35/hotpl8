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
test('concurrent turns cannot change auth; approval responses and steering still flow', async () => {
  const h = harness(); await opened(h);
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't' } });
  h.select('b'); const before = h.requests.length;
  await h.bridge.client({ id: 4, method: 'turn/start', params: { threadId: 't' } });
  assert.equal(h.requests.length, before); assert.match(h.client.at(-1).error.message, /routing_busy/);
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
test('child turns pin account after parent completion', async () => {
  const h = harness(); await opened(h);
  h.bridge.native({ method: 'turn/started', params: { threadId: 'child' } });
  h.bridge.native({ method: 'turn/completed', params: { threadId: 't' } });
  await h.bridge.client({ id: 3, method: 'turn/start', params: { threadId: 't' } });
  assert.match(h.client.at(-1).error.message, /routing_busy/); h.bridge.close();
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
test('explicit compaction receives the same quota admission and account pinning', async () => {
  const h = harness(); await opened(h); h.select('b');
  await h.bridge.client({ id: 7, method: 'thread/compact/start', params: { threadId: 't' } });
  assert.equal(h.bridge.route.slot, 'b'); assert.equal(h.bridge.active.has('t'), true);
  assert.deepEqual(h.native.at(-1).params, { threadId: 't' });
  h.bridge.native({ id: 7, error: { code: 1 } }); assert.equal(h.bridge.active.size, 0);
  h.bridge.close();
});
test('T3 MCP launch arguments preserve its callback and environment reference', () => {
  assert.doesNotThrow(() => validateArgs(['-c', 'mcp_servers.t3-code.url=http://127.0.0.1:1234/mcp', '-c', 'mcp_servers.t3-code.bearer_token_env_var="T3_MCP_BEARER_TOKEN"']));
});
test('editing a managed provider home cannot silently resume a different conversation store', () => {
  assert.doesNotThrow(() => assertSharedHome('fixture/shared', 'fixture/shared/'));
  assert.throws(() => assertSharedHome('fixture/shared', 'fixture/another'), /routing_home_conflict/);
});
