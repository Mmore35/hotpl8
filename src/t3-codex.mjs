// Opt-in Codex binary adapter. Tokens exist only in private pipes and memory.
import { spawn } from 'node:child_process';
import { readFileSync, watch } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const LIMIT = 16 * 1024 * 1024; // Images and tool responses can exceed the MCP limit.
const error = code => Object.assign(new Error(code), { code });
const idKey = id => JSON.stringify(id);
const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const blockedEnv = ['OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'CODEX_SQLITE_HOME', 'OPENAI_BASE_URL'];

function killTree(proc) {
  if (!proc.pid || proc.exitCode !== null) return;
  if (process.platform === 'win32') {
    const killer = spawn(join(process.env.SystemRoot, 'System32/taskkill.exe'), ['/PID', String(proc.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    killer.on('error', () => proc.kill());
  } else proc.kill();
}

export function assertEnvironment(env) {
  if (blockedEnv.some(k => env[k])) throw error('routing_environment_conflict');
}

export function assertSharedHome(configured, inherited) {
  const normalize = value => process.platform === 'win32' ? resolve(value).toLowerCase() : resolve(value);
  if (inherited && normalize(configured) !== normalize(inherited)) throw error('routing_home_conflict');
}

export function assertConfig(config = {}) {
  if ((config.model_provider && config.model_provider !== 'openai') ||
      config.model_providers?.openai?.base_url ||
      config.openai_base_url ||
      (config.chatgpt_base_url && !/^https:\/\/chatgpt\.com\/backend-api\/?$/.test(config.chatgpt_base_url)) ||
      (config.cli_auth_credentials_store && config.cli_auth_credentials_store !== 'ephemeral')) {
    throw error('routing_config_conflict');
  }
}

// Only display/reasoning/MCP feature overrides belong on the bridge command line.
// Subscription transport, home and authentication must not be overridden.
export function validateArgs(args, exec = false) {
  const allowed = new Set(exec
    ? ['--ephemeral', '--skip-git-repo-check', '--json', '--color', '--sandbox', '-s', '--model', '-m', '--output-schema', '--output-last-message', '-o', '--image', '-i', '-']
    : ['--stdio']);
  const valued = new Set(['--color', '--sandbox', '-s', '--model', '-m', '--output-schema', '--output-last-message', '-o', '--image', '-i']);
  let model;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '-c' || arg === '--config') {
      const value = args[++i];
      if (!value || !/^(model_reasoning_effort|model_reasoning_summary|service_tier|mcp_servers\.[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+)=/.test(value)) throw error('routing_argument_rejected');
      continue;
    }
    if (!allowed.has(arg)) throw error('routing_argument_rejected');
    if (valued.has(arg)) {
      const value = args[++i];
      if (!value || value.startsWith('--')) throw error('routing_argument_rejected');
      if (arg === '--model' || arg === '-m') model = value;
      if ((arg === '-s' || arg === '--sandbox') && value !== 'read-only') throw error('routing_argument_rejected');
    }
  }
  return { model };
}

export function readLines(stream, onMessage, onFailure, onEnd = () => {}) {
  let buffer = '';
  stream.setEncoding('utf8');
  stream.on('data', chunk => {
    buffer += chunk;
    if (Buffer.byteLength(buffer) > LIMIT) { onFailure(error('routing_frame_too_large')); return; }
    let end;
    while ((end = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, end).replace(/^\uFEFF/, '');
      buffer = buffer.slice(end + 1);
      if (!line.trim()) continue;
      try {
        const message = JSON.parse(line);
        if (!message || Array.isArray(message) || typeof message !== 'object') throw error('routing_invalid_frame');
        onMessage(message);
      } catch { onFailure(error('routing_invalid_frame')); return; }
    }
  });
  stream.on('error', () => onFailure(error('routing_pipe_failed')));
  stream.on('end', () => {
    if (buffer.trim()) onFailure(error('routing_incomplete_frame'));
    else onEnd();
  });
}

export function createBroker(config) {
  return request => new Promise((resolveRoute, reject) => {
    const proc = spawn(config.powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'codex-route.ps1'),
      '-StateDirectory', config.stateDirectory, '-Executable', config.codex], { windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'] });
    let output = '', failed = false;
    const fail = () => { failed = true; killTree(proc); reject(error('routing_broker_failed')); };
    const timer = setTimeout(fail, request.operation === 'refresh' ? 8500 : 25000);
    proc.on('error', fail);
    proc.stdin.on('error', fail);
    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', data => { output += data; if (output.length > 65536) fail(); });
    proc.on('close', code => {
      clearTimeout(timer);
      if (failed) return;
      try {
        const result = JSON.parse(output.replace(/^\uFEFF/, ''));
        output = '';
        if (code !== 0 || result.error) throw error(/^routing_[a-z_]+$/.test(result.error) ? result.error : 'routing_broker_failed');
        if (!result.slot || !result.home || !result.model || !result.meter) throw error('routing_broker_failed');
        resolveRoute(result);
      } catch (err) { reject(err.code ? err : error('routing_broker_failed')); }
    });
    proc.stdin.end(JSON.stringify(request) + '\n');
  });
}

// The dispatcher is transport-independent so tests drive the exact production state machine.
export class CodexBridge {
  constructor({ broker, toNative, toClient, cwd, onFatal = () => {}, onRoutingError = () => {}, timeoutMs = 30000 }) {
    Object.assign(this, { broker, toNative, toClient, cwd, onFatal, onRoutingError, timeoutMs });
    this.internal = new Map(); this.pending = new Map(); this.threads = new Map();
    this.active = new Map(); this.reservations = new Map(); this.route = null; this.initialized = false; this.closed = false;
    this.counter = 0; this.serial = Promise.resolve();
    this.routing = Promise.resolve(); this.observing = null; this.observationPending = false;
    this.rebinding = null; this.executingModels = new Map();
  }
  rpc(method, params) {
    const id = `hotpl8-internal-${++this.counter}`;
    return new Promise((resolveResult, reject) => {
      const timer = setTimeout(() => { this.internal.delete(id); reject(error('routing_native_timeout')); }, this.timeoutMs);
      this.internal.set(id, { resolve: resolveResult, reject, timer });
      this.toNative({ id, method, params });
    });
  }
  fail(message, code = 'routing_failed') {
    if (own(message, 'id')) this.toClient({ id: message.id, error: { code: -32001, message: `HotPl8: ${code}. Check HotPl8 status/refresh and the T3 integration diagnostics.` } });
  }
  client(message) {
    if (typeof message.id === 'string' && message.id.startsWith('hotpl8-internal-')) { this.fail(message, 'routing_reserved_id'); return Promise.resolve(); }
    // Approval responses must never wait behind a turn admission or token refresh.
    if (!message.method) { this.toNative(message); return Promise.resolve(); }
    // Native input/control must remain responsive during private quota reads.
    const thread = this.threads.get(message.params?.threadId);
    const followup = message.method === 'turn/start' && this.active.has(message.params?.threadId) && thread &&
      (!message.params.model || message.params.model === thread.model) && (!message.params.cwd || message.params.cwd === thread.cwd);
    if (this.initialized && (followup || ['turn/steer', 'turn/interrupt'].includes(message.method))) {
      return this.dispatch(message).catch(err => this.fail(message, err.code || 'routing_failed'));
    }
    this.serial = this.serial.then(() => this.dispatch(message)).catch(err => this.fail(message, err.code || 'routing_failed'));
    return this.serial;
  }
  select(model, cwd = this.cwd, background = false) {
    const operation = this.routing.then(() => this.selectNow(model, cwd, background));
    this.routing = operation.catch(() => {});
    return operation;
  }
  async selectNow(model, cwd, background) {
    if (this.closed) throw error('routing_closed');
    // Authentication is process-wide, including native children. Unknown child
    // models need a native snapshot; role configurations can override the parent.
    const ids = new Set([...this.active.keys(), ...this.reservations.values()]);
    for (const id of ids) {
      if (!this.threads.get(id)?.model) {
        const snapshot = await this.rpc('thread/read', { threadId: id, includeTurns: false });
        if (!snapshot.thread?.model || snapshot.thread.modelProvider !== 'openai') throw error('routing_model_unknown');
        this.threads.set(id, { model: snapshot.thread.model, cwd: snapshot.thread.cwd || this.cwd });
      }
    }
    const activeModels = () => [...new Set([
      ...[...new Set([...this.active.keys(), ...this.reservations.values()])]
        .flatMap(id => [this.threads.get(id)?.model, this.executingModels.get(id)]),
      ...[...this.reservations.keys()].map(key => this.pending.get(key)?.model)
    ].filter(Boolean))];
    const models = [...new Set([model, ...activeModels()].filter(Boolean))];
    // Background observations have no new inference to admit. Select only for
    // work still present when this serialized operation runs, not the model of
    // whichever (possibly completed) thread last changed the selected account.
    if (background && !models.length) return this.route;
    const route = await this.broker({ operation: 'select', intent: background ? 'rebind' : 'admit',
      model: model || models[0], models, cwd, previousSlot: this.route?.slot, criticalState: this.route?.criticalState });
    if (this.closed) throw error('routing_closed');
    if ([...this.active.keys()].some(id => !this.threads.get(id)?.model) || activeModels().some(m => !models.includes(m))) throw error('routing_model_changed');
    if (!route.auth?.accessToken || !route.auth?.chatgptAccountId) throw error('routing_auth_unavailable');
    const changed = this.route?.accountId !== route.auth.chatgptAccountId || this.route?.slot !== route.slot;
    if (changed) {
      // Native adopts external auth for later requests and reconnects account-bound
      // websockets. In-flight requests finish under their original identity.
      this.rebinding = { slot: route.slot, model: route.model, meter: route.meter, accountId: route.auth.chatgptAccountId };
      try { await this.rpc('account/login/start', { type: 'chatgptAuthTokens', ...route.auth }); }
      catch (err) {
        // Any failed apply has an unknown binding. Do not reuse the old receipt
        // or replay a turn; a fresh explicit admission must validate again.
        this.route = null;
        if (err.code === 'routing_native_timeout') this.onFatal(err);
        throw err;
      }
      finally { this.rebinding = null; }
    }
    if (this.closed) throw error('routing_closed');
    // Retain account identity, not a second access-token cache.
    const criticalState = route.criticalState && { ...route.criticalState, selected: route.slot,
      selectedAt: changed ? new Date().toISOString() : (this.route?.criticalState?.selectedAt || route.criticalState.selectedAt) };
    this.route = { slot: route.slot, model: route.model, meter: route.meter, accountId: route.auth.chatgptAccountId,
      criticalState };
    return route;
  }
  observe() {
    if (this.closed || !this.initialized || !(this.active.size || this.reservations.size)) return Promise.resolve();
    this.observationPending = true;
    if (this.observing) return this.observing;
    this.observing = (async () => {
      while (this.observationPending && !this.closed) {
        this.observationPending = false;
        try { await this.select(undefined, this.cwd, true); }
        catch (err) { if (!this.closed) this.onRoutingError(/^routing_[a-z_]+$/.test(err.code) ? err.code : 'routing_failed'); }
      }
    })().finally(() => { this.observing = null; });
    return this.observing;
  }
  async checkConfig(cwd = this.cwd) {
    const result = await this.rpc('config/read', { includeLayers: false, cwd });
    if (!result?.config) throw error('routing_config_unknown');
    assertConfig(result.config);
    return result.config;
  }
  async dispatch(message) {
    if (this.closed) throw error('routing_closed');
    const { method, params = {} } = message;
    if (method === 'initialize') {
      if (this.initialized) throw error('routing_already_initialized');
      const result = await this.rpc('initialize', { ...params, capabilities: { ...params.capabilities, experimentalApi: true } });
      this.toNative({ method: 'initialized' });
      const config = await this.checkConfig();
      await this.select(config.model);
      this.initialized = true;
      this.toClient({ id: message.id, result });
      return;
    }
    if (!this.initialized) throw error('routing_not_initialized');
    if (method === 'initialized') return;
    // T3 must use native enrollment to change authentication. Never let its logout
    // or credit-redemption UI mutate an implicitly selected subscription.
    if (method.startsWith('account/') && !['account/read', 'account/rateLimits/read'].includes(method)) throw error('routing_account_operation_rejected');
    if (method === 'config/value/write' || method === 'config/batchWrite') throw error('routing_config_write_rejected');
    if (method === 'review/start') throw error('routing_unsupported_inference');
    if (method === 'thread/start' || method === 'thread/resume' || method === 'thread/fork') {
      if (params.modelProvider && params.modelProvider !== 'openai') throw error('routing_config_conflict');
      if (params.config && Object.keys(params.config).some(k => !['model_reasoning_effort', 'model_reasoning_summary', 'service_tier', 'mcp_servers'].includes(k))) throw error('routing_config_conflict');
      const config = await this.checkConfig(params.cwd || this.cwd);
      const model = params.model || config.model;
      // No inference is sent while opening/resuming a thread; model admission happens
      // on turn/start, where T3 can choose a different model than the initial one.
      this.pending.set(idKey(message.id), { method, model, cwd: params.cwd || this.cwd });
    }
    if (method === 'turn/start' || method === 'thread/compact/start') {
      const thread = this.threads.get(params.threadId);
      if (!thread) throw error('routing_thread_unknown');
      if (method === 'turn/start' && this.active.has(params.threadId) &&
          (!params.model || params.model === thread.model) && (!params.cwd || params.cwd === thread.cwd)) {
        // Native turn/start is an input append while this thread is active. It
        // retains the native TurnStartResponse, including the existing turn ID.
        this.toNative(message);
        return;
      }
      const config = await this.checkConfig(params.cwd || thread.cwd);
      const model = params.model || thread.model || config.model;
      const route = await this.select(model, params.cwd || thread.cwd);
      this.reservations.set(idKey(message.id), params.threadId);
      this.pending.set(idKey(message.id), { method, threadId: params.threadId, model: route.model });
      if (method === 'turn/start') message = { ...message, params: { ...params, model: route.model } };
    }
    this.toNative(message);
  }
  native(message) {
    if (own(message, 'id') && !message.method && this.internal.has(message.id)) {
      const pending = this.internal.get(message.id); this.internal.delete(message.id); clearTimeout(pending.timer);
      if (message.error) pending.reject(error('routing_native_rejected')); else pending.resolve(message.result);
      return;
    }
    if (message.method === 'account/chatgptAuthTokens/refresh') {
      void this.refresh(message); return;
    }
    if (own(message, 'id') && !message.method) {
      const pending = this.pending.get(idKey(message.id));
      this.pending.delete(idKey(message.id));
      this.reservations.delete(idKey(message.id));
      if (pending?.method === 'turn/start' && !message.error && this.threads.has(pending.threadId)) this.threads.get(pending.threadId).model = pending.model;
      if (pending && pending.method.startsWith('thread/') && !message.error && message.result?.thread?.id) {
        this.threads.set(message.result.thread.id, { model: message.result.model || message.result.thread.model || pending.model, cwd: pending.cwd });
      }
    }
    if (message.method === 'thread/started' && message.params?.thread?.id) {
      const thread = message.params.thread;
      this.threads.set(thread.id, { model: thread.model, cwd: thread.cwd || this.cwd });
    }
    if (message.method === 'model/rerouted' && this.active.get(message.params?.threadId) === message.params?.turnId) {
      this.executingModels.set(message.params.threadId, message.params.toModel);
      void this.observe();
    }
    if (message.method === 'turn/started' && message.params?.threadId) this.active.set(message.params.threadId, message.params.turn?.id || null);
    if (message.method === 'turn/completed' && message.params?.threadId &&
        (!this.active.get(message.params.threadId) || this.active.get(message.params.threadId) === message.params.turn?.id)) {
      this.active.delete(message.params.threadId); this.executingModels.delete(message.params.threadId);
    }
    if (message.method === 'thread/status/changed' && message.params?.threadId) {
      if (message.params.status?.type === 'active' && !this.active.has(message.params.threadId)) this.active.set(message.params.threadId, null);
      if (message.params.status?.type === 'idle' && !this.active.get(message.params.threadId)) this.active.delete(message.params.threadId);
    }
    // Treat notifications only as wakeups: their quota may belong to an old
    // in-flight request. The broker verifies native account identity and quota.
    if (message.method === 'account/rateLimits/updated') void this.observe();
    // Internal login notifications have no useful T3 request correlation.
    if (message.method === 'account/login/completed') return;
    this.toClient(message);
  }
  async refresh(message) {
    const route = this.rebinding || this.route;
    try {
      if (!route || message.params?.previousAccountId !== route.accountId) throw error('routing_binding_changed');
      const fresh = await this.broker({ operation: 'refresh', previousSlot: route.slot, accountId: route.accountId, model: route.model, cwd: this.cwd });
      if (fresh.auth?.chatgptAccountId !== route.accountId || (this.rebinding || this.route)?.accountId !== route.accountId) throw error('routing_binding_changed');
      this.toNative({ id: message.id, result: fresh.auth });
    } catch {
      this.toNative({ id: message.id, error: { code: -32001, message: 'HotPl8: routing_refresh_failed' } });
    }
  }
  close() {
    this.closed = true;
    for (const pending of this.internal.values()) { clearTimeout(pending.timer); pending.reject(error('routing_closed')); }
    this.internal.clear(); this.route = null; this.rebinding = null; this.executingModels.clear();
    this.active.clear(); this.reservations.clear(); this.observationPending = false;
  }
}

export async function main(config, args) {
  const broker = createBroker(config);
  const verb = args[0];
  if (verb === '--version' || verb === '-V') {
    if (args.length !== 1) throw error('routing_argument_rejected');
    const child = spawn(config.codex, args, { stdio: 'inherit', windowsHide: true });
    await new Promise((done, fail) => { child.on('error', fail); child.on('exit', code => { process.exitCode = code ?? 1; done(); }); });
    return;
  }
  assertEnvironment(process.env);
  assertSharedHome(config.sharedHome, process.env.CODEX_HOME);
  if (verb === 'exec') {
    const { model } = validateArgs(args.slice(1), true);
    if (!model) throw error('routing_model_unknown');
    const route = await broker({ operation: 'exec', model, cwd: process.cwd() });
    const child = spawn(config.codex, args, { env: { ...process.env, CODEX_HOME: route.home, HOTPL8_SLOT: route.slot }, stdio: 'inherit', windowsHide: true });
    await new Promise((done, fail) => { child.on('error', fail); child.on('exit', code => { process.exitCode = code ?? 1; done(); }); });
    return;
  }
  if (verb !== 'app-server') throw error('routing_argument_rejected');
  validateArgs(args.slice(1));
  const child = spawn(config.codex, [...args, '-c', 'cli_auth_credentials_store="ephemeral"'], {
    env: { ...process.env, CODEX_HOME: config.sharedHome }, stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true
  });
  const write = (stream, value) => {
    const text = JSON.stringify(value) + '\n';
    if (stream.writableLength + Buffer.byteLength(text) > 2 * LIMIT) throw error('routing_output_limit');
    stream.write(text);
  };
  let stopped = false;
  const stop = failed => {
    if (stopped) return;
    stopped = true; watcher?.close(); bridge.close(); child.stdin.end();
    const timer = setTimeout(() => killTree(child), 500); timer.unref();
    process.stdin.pause(); process.exitCode = failed ? 1 : 0;
  };
  let watcher;
  const diagnostic = code => process.stderr.write(`HotPl8: ${code}\n`);
  const bridge = new CodexBridge({ broker, cwd: process.cwd(), toNative: msg => write(child.stdin, msg), toClient: msg => write(process.stdout, msg),
    onFatal: () => stop(true), onRoutingError: diagnostic });
  // Subscribe to the existing collector's atomic publications, including rename.
  // No second quota collector or periodic account-switch scheduler is introduced.
  watcher = watch(config.stateDirectory, (_event, filename) => {
    if (!filename || ['status.json', 'policy.json', 'hold.json', 'codex-state.json', 'automation-pause.json', 'automation-leases.json'].includes(String(filename))) void bridge.observe();
  });
  watcher.on('error', () => diagnostic('routing_observation_failed'));
  child.on('error', () => stop(true));
  child.stdin.on('error', () => stop(true));
  process.stdout.on('error', () => stop(true));
  child.on('exit', code => stop(code !== 0));
  readLines(child.stdout, msg => bridge.native(msg), () => stop(true));
  readLines(process.stdin, msg => { void bridge.client(msg); }, () => stop(true), () => stop(false));
  process.on('SIGTERM', () => stop(false)); process.on('SIGINT', () => stop(false));
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    if (process.argv[2] !== '--bridge-config') throw error('routing_config_missing');
    const config = JSON.parse(readFileSync(process.argv[3], 'utf8').replace(/^\uFEFF/, ''));
    if (config.schemaVersion !== 1 || !config.codex || !config.sharedHome || !config.stateDirectory || !config.powershell) throw error('routing_config_invalid');
    await main(config, process.argv.slice(4));
  } catch (err) {
    process.stderr.write(`HotPl8: ${/^routing_[a-z_]+$/.test(err.code) ? err.code : 'routing_failed'}\n`);
    process.exitCode = 1;
  }
}
