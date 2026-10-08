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
  return (request, signal) => new Promise((resolveRoute, reject) => {
    const proc = spawn(config.powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(here, 'codex-route.ps1'),
      '-StateDirectory', config.stateDirectory, '-Executable', config.codex], { windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'] });
    let output = '', failed = false;
    const fail = (code = 'routing_broker_failed') => {
      if (failed) return;
      failed = true; clearTimeout(timer); killTree(proc); reject(error(code));
    };
    // The broker ends its own validation after 30 s (refresh: 6.5 s) and names the
    // reason. The rest is PowerShell starting, which takes seconds on a saturated machine.
    const timer = setTimeout(() => fail(), request.operation === 'refresh' ? 8500 : 40000);
    // Stopping the broker also ends its native read and frees the account lock.
    if (signal?.aborted) fail('routing_cancelled');
    else signal?.addEventListener('abort', () => fail('routing_cancelled'), { once: true });
    proc.on('error', () => fail());
    proc.stdin.on('error', () => fail());
    proc.stdout.setEncoding('utf8');
    proc.stdout.on('data', data => { output += data; if (output.length > 65536) fail(); });
    proc.on('close', code => {
      clearTimeout(timer);
      if (failed) return;
      try {
        const result = JSON.parse(output.replace(/^\uFEFF/, ''));
        output = '';
        if (code !== 0 || result.error) throw error(/^routing_[a-z_]+$/.test(result.error) ? result.error : 'routing_broker_failed');
        if (!result.slot || !result.home || !result.meter) throw error('routing_broker_failed');
        resolveRoute(result);
      } catch (err) { reject(err.code ? err : error('routing_broker_failed')); }
    });
    proc.stdin.end(JSON.stringify(request) + '\n');
  });
}

// The waiter is continue.ps1, the same script Claude runs as its hook, so both providers
// share one readiness rule. It sleeps until HotPl8 has an account ready (exit 2) or stands
// down (anything else), and ends by itself if this bridge goes away. `after` is the time
// of the failure; `held` asks again for a continue that could not be sent when it was due.
export function createWaiter(config) {
  return (threadId, slot, after, held) => {
    const proc = spawn(config.powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(here, '..', 'continue.ps1'),
      '-Provider', 'codex', '-StateDirectory', config.stateDirectory, '-Conversation', threadId, '-Slot', slot,
      '-After', after, '-WatchPid', String(process.pid), ...(held ? ['-Held'] : [])], { windowsHide: true, stdio: 'ignore' });
    return { done: new Promise(done => { proc.on('error', () => done(0)); proc.on('exit', code => done(code)); }), kill: () => killTree(proc) };
  };
}

// The dispatcher is transport-independent so tests drive the exact production state machine.
export class CodexBridge {
  constructor({ broker, waiter = null, toNative, toClient, cwd, onFatal = () => {}, onRoutingError = () => {}, timeoutMs = 30000, quotaIntervalMs = 60000 }) {
    Object.assign(this, { broker, waiter, toNative, toClient, cwd, onFatal, onRoutingError, timeoutMs, quotaIntervalMs });
    this.internal = new Map(); this.pending = new Map(); this.threads = new Map(); this.waiters = new Map();
    this.active = new Map(); this.reservations = new Map(); this.route = null; this.initialized = false; this.closed = false;
    this.counter = 0; this.serial = Promise.resolve();
    this.routing = Promise.resolve(); this.observing = null; this.observationPending = false;
    this.rebinding = null;
    this.brokers = new Set(); this.background = null; this.admissions = 0; this.validatedAt = 0; this.quotaTimer = null;
  }
  async ask(request, background = false) {
    const control = new AbortController();
    this.brokers.add(control);
    if (background) this.background = control;
    try { return await this.broker(request, control.signal); }
    finally { this.brokers.delete(control); if (this.background === control) this.background = null; }
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
    // The owner wrote first: their message is the continuation, so none is sent for them.
    if (message.method === 'turn/start') this.stopWaiting(message.params?.threadId);
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
  select(cwd = this.cwd, background = false) {
    // Someone is waiting on an admission's reply. A background validation in its
    // way is abandoned, running or queued: the admission validates afresh and the
    // next wakeup repeats the background one.
    if (!background) { this.admissions++; this.background?.abort(); }
    const operation = this.routing.then(() => this.selectNow(cwd, background));
    this.routing = operation.catch(() => {});
    if (!background) operation.catch(() => {}).then(() => { this.admissions--; });
    return operation;
  }
  async selectNow(cwd, background) {
    if (this.closed) throw error('routing_closed');
    if (background && (this.admissions || !(this.active.size || this.reservations.size))) return this.route;
    this.validatedAt = Date.now();
    const route = await this.ask({ operation: 'select', intent: background ? 'rebind' : 'admit',
      cwd, previousSlot: this.route?.slot, criticalState: this.route?.criticalState }, background);
    if (this.closed) throw error('routing_closed');
    if (!route.auth?.accessToken || !route.auth?.chatgptAccountId) throw error('routing_auth_unavailable');
    const changed = this.route?.accountId !== route.auth.chatgptAccountId || this.route?.slot !== route.slot;
    // Native account/login/start can revoke the old application's network
    // permission, including running turns and MCP requests. A successful login
    // response does not prove in-flight work survived. Recheck AFTER validation:
    // children or pending admissions may have become active while it awaited I/O.
    if (changed && (this.active.size || this.reservations.size)) {
      if (background) return this.route;
      throw error('routing_account_change_deferred');
    }
    if (changed) {
      // Only change the process-wide account between turns, after child work and
      // pending admissions have also drained. Never replay an interrupted turn.
      this.rebinding = { slot: route.slot, meter: route.meter, accountId: route.auth.chatgptAccountId };
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
    this.route = { slot: route.slot, meter: route.meter, accountId: route.auth.chatgptAccountId,
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
        try { await this.select(this.cwd, true); }
        catch (err) {
          // Abandoned for an admission, or another reader held the account lock:
          // this validation was skipped, not failed.
          if (!this.closed && !['routing_cancelled', 'routing_account_busy'].includes(err.code)) this.onRoutingError(/^routing_[a-z_]+$/.test(err.code) ? err.code : 'routing_failed');
        }
      }
    })().finally(() => { this.observing = null; });
    return this.observing;
  }
  // Native Codex reports quota after every model response. Each validation starts
  // a broker and a native read under the account lock that admissions need, and
  // the collector itself reads no more than once a minute, so these wakeups share
  // one validation per interval. The last one in an interval is not lost.
  quotaChanged() {
    if (this.closed || this.quotaTimer) return;
    const wait = this.validatedAt + this.quotaIntervalMs - Date.now();
    if (wait <= 0) { void this.observe(); return; }
    this.quotaTimer = setTimeout(() => { this.quotaTimer = null; this.quotaChanged(); }, wait);
    this.quotaTimer.unref?.();
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
      await this.checkConfig();
      await this.select();
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
      // Keep native thread metadata for active follow-ups; account selection
      // does not depend on the model chosen when opening or resuming a thread.
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
      await this.select(params.cwd || thread.cwd);
      this.reservations.set(idKey(message.id), params.threadId);
      this.pending.set(idKey(message.id), { method, threadId: params.threadId, model });
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
    if (message.method === 'turn/started' && message.params?.threadId) this.active.set(message.params.threadId, message.params.turn?.id || null);
    if (message.method === 'turn/completed' && message.params?.threadId &&
        (!this.active.get(message.params.threadId) || this.active.get(message.params.threadId) === message.params.turn?.id)) {
      this.active.delete(message.params.threadId);
    }
    if (message.method === 'turn/completed' && message.params?.turn?.status === 'failed' &&
        message.params.turn.error?.codexErrorInfo === 'usageLimitExceeded') this.wait(message.params.threadId);
    if (message.method === 'thread/status/changed' && message.params?.threadId) {
      if (message.params.status?.type === 'active' && !this.active.has(message.params.threadId)) this.active.set(message.params.threadId, null);
      if (message.params.status?.type === 'idle' && !this.active.get(message.params.threadId)) this.active.delete(message.params.threadId);
    }
    this.drained();
    // Treat notifications only as wakeups: their quota may belong to an old
    // in-flight request. The broker verifies native account identity and quota.
    if (message.method === 'account/rateLimits/updated') this.quotaChanged();
    // Internal login notifications have no useful T3 request correlation.
    if (message.method === 'account/login/completed') return;
    this.toClient(message);
  }
  async refresh(message) {
    const route = this.rebinding || this.route;
    try {
      if (!route || message.params?.previousAccountId !== route.accountId) throw error('routing_binding_changed');
      const fresh = await this.ask({ operation: 'refresh', previousSlot: route.slot, accountId: route.accountId, cwd: this.cwd });
      if (fresh.auth?.chatgptAccountId !== route.accountId || (this.rebinding || this.route)?.accountId !== route.accountId) throw error('routing_binding_changed');
      this.toNative({ id: message.id, result: fresh.auth });
    } catch {
      this.toNative({ id: message.id, error: { code: -32001, message: 'HotPl8: routing_refresh_failed' } });
    }
  }
  // A turn that died on a usage limit is continued once, when the waiter says an account
  // is ready. The continue is a new turn: the failed turn's input is never sent again.
  // The waiter stays registered until the continue is sent or given up, so the owner
  // writing first cancels it at any point.
  wait(threadId) {
    if (!this.waiter || this.closed || !this.threads.has(threadId) || !this.route?.slot) return;
    // A continue that was held stands. A new waiter would stand down on the
    // ten-minute rule and take it along.
    const current = this.waiters.get(threadId);
    if (current?.held || current?.again) return;
    this.watch(threadId, this.route.slot, new Date().toISOString(), false);
  }
  // `slot` and `after` are the account and the time of the failure. `again` starts the
  // waiter for a continue that was held.
  watch(threadId, slot, after, again) {
    this.stopWaiting(threadId);
    const waiter = { ...this.waiter(threadId, slot, after, again), slot, after, again, held: false };
    this.waiters.set(threadId, waiter);
    waiter.done.then(code => {
      if (this.waiters.get(threadId) !== waiter) return;
      if (code !== 2) { this.waiters.delete(threadId); return; }
      // Any failure drops this continue; the owner's next message works as it always has.
      this.serial = this.serial.then(() => this.resume(threadId, waiter)).catch(() => {
        if (this.waiters.get(threadId) === waiter) this.waiters.delete(threadId);
        if (!this.closed) this.onRoutingError('routing_continue_failed');
      });
    });
  }
  stopWaiting(threadId) {
    this.waiters.get(threadId)?.kill();
    this.waiters.delete(threadId);
  }
  // The work that kept a held continue from changing the account has ended. How long
  // that took is unbounded, so the bridge does not send on the old decision: the waiter
  // decides again, and the setting, a pause and the six hours apply as to any continue.
  drained() {
    if (this.active.size || this.reservations.size) return;
    for (const [threadId, waiter] of [...this.waiters]) if (waiter.held) this.watch(threadId, waiter.slot, waiter.after, true);
  }
  async resume(threadId, waiter) {
    const thread = this.threads.get(threadId);
    // Still registered means the owner has not written since the waiter finished.
    if (this.waiters.get(threadId) !== waiter) return;
    if (this.closed || !thread || this.active.has(threadId)) { this.waiters.delete(threadId); return; }
    await this.checkConfig(thread.cwd);
    try { await this.select(thread.cwd); }
    catch (err) {
      if (err.code !== 'routing_account_change_deferred') throw err;
      // Sub-agents of this conversation still run on the account that must be left.
      // Changing it now could end them, so the continue is held until they finish.
      waiter.held = true;
      return;
    }
    // The owner wrote while the account was validated: their message is the continuation.
    if (this.waiters.get(threadId) !== waiter) return;
    this.waiters.delete(threadId);
    const reservation = `continue:${threadId}`;
    this.reservations.set(reservation, threadId);
    try { await this.rpc('turn/start', { threadId, input: [{ type: 'text', text: 'Automated message: continue.', text_elements: [] }] }); }
    finally { this.reservations.delete(reservation); }
  }
  close() {
    this.closed = true;
    for (const waiter of this.waiters.values()) waiter.kill();
    this.waiters.clear();
    // A broker left running would keep its native read and the account lock.
    for (const control of this.brokers) control.abort();
    clearTimeout(this.quotaTimer); this.quotaTimer = null;
    for (const pending of this.internal.values()) { clearTimeout(pending.timer); pending.reject(error('routing_closed')); }
    this.internal.clear(); this.route = null; this.rebinding = null;
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
    validateArgs(args.slice(1), true);
    const route = await broker({ operation: 'exec', cwd: process.cwd() });
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
  const bridge = new CodexBridge({ broker, waiter: createWaiter(config), cwd: process.cwd(), toNative: msg => write(child.stdin, msg), toClient: msg => write(process.stdout, msg),
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
