// Opt-in installed Claude Code qualification for automatic continue; synthetic login and localhost only.
//
// After a turn dies on a usage limit, does the installed Claude Code run the hook HotPl8
// writes, keep it waiting, and then continue the same conversation with one new turn? Three
// cases: a different account is switched in, the same account's limit resets, and a managed
// installation whose hook finds its current release by itself. The hook is installed by
// `hotpl8 continue` into a disposable Claude profile; the account state a collector would
// write is written here. Never uses a real Claude profile, login or the model service.
//
// usage: node tests/probe-claude-continue.mjs --claude <native executable> --scratch <existing disposable directory> [--output <file>]
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const options = {};
for (let i = 2; i < process.argv.length; i += 2) options[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
if (!options.claude || !options.scratch || !fs.statSync(options.scratch).isDirectory()) {
  console.error('usage: node tests/probe-claude-continue.mjs --claude <native executable> --scratch <existing disposable directory> [--output <file>]');
  process.exit(64);
}
const powershell = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
const wake = 'Automated message: continue.';
const sleep = ms => new Promise(done => setTimeout(done, ms));
const until = async (test, seconds) => {
  for (const end = Date.now() + seconds * 1000; Date.now() < end; await sleep(100)) if (test()) return true;
  return false;
};
const stamp = seconds => new Date(Date.now() + seconds * 1000).toISOString();
const replace = (file, text) => { fs.writeFileSync(file + '.tmp', text); fs.renameSync(file + '.tmp', file); };
const login = account => JSON.stringify({ claudeAiOauth: {
  accessToken: 'fixture-login-' + account, refreshToken: 'fixture-refresh-' + account, expiresAt: Date.now() + 86400000,
  scopes: ['user:inference', 'user:profile'], subscriptionType: 'max' } });
// What a HotPl8 collection leaves behind: the account in use, the one selected, and when each was read.
const snapshot = (active, selected, read) => JSON.stringify({ schemaVersion: 2, active, providerOverview: { claude: { selected } },
  slots: [{ slot: 1, observedAt: read[0] }, { slot: 2, observedAt: read[1] }] });

async function run(name, dir, { sameAccount = false, managed = false }) {
  const requests = [];
  const limited = new Set(['a']);
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      if (!req.url.startsWith('/v1/messages') || req.url.includes('count_tokens')) {
        res.writeHead(404, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'not_found_error', message: 'fixture' } }));
        return;
      }
      let json = {};
      try { json = JSON.parse(body); } catch {}
      const account = String(req.headers.authorization || '').replace(/^Bearer fixture-login-/, '');
      const text = JSON.stringify((json.messages || []).filter(message => message.role === 'user'));
      const refused = limited.has(account);
      requests.push({ n: requests.length + 1, account, refused, hasOriginal: text.includes('fixture start'), hasContinue: text.includes(wake) });
      if (refused) {
        const reset = String(Math.floor(Date.now() / 1000) + 3600);
        res.writeHead(429, { 'content-type': 'application/json', 'retry-after': '3600', 'x-should-retry': 'false',
          'anthropic-ratelimit-unified-status': 'rejected', 'anthropic-ratelimit-unified-reset': reset,
          'anthropic-ratelimit-unified-representative-claim': 'five_hour', 'anthropic-ratelimit-unified-5h-status': 'rejected',
          'anthropic-ratelimit-unified-5h-reset': reset, 'anthropic-ratelimit-unified-5h-utilization': '1.01',
          'anthropic-ratelimit-unified-overage-status': 'rejected', 'anthropic-ratelimit-unified-overage-disabled-reason': 'org_level_disabled' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'rate_limit_error', message: 'This request would exceed your account\'s rate limit. Please try again later.' } }));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      const emit = (event, data) => res.write('event: ' + event + '\ndata: ' + JSON.stringify({ type: event, ...data }) + '\n\n');
      emit('message_start', { message: { id: 'msg_fixture_' + requests.length, type: 'message', role: 'assistant', model: json.model, content: [],
        stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } });
      emit('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
      emit('content_block_delta', { index: 0, delta: { type: 'text_delta', text: 'fixture done' } });
      emit('content_block_stop', { index: 0 });
      emit('message_delta', { delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } });
      emit('message_stop', {});
      res.end();
    });
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));

  // Awkward on purpose: every path the hook is handed has a space in it.
  const profile = path.join(dir, 'claude profile'), state = path.join(dir, 'hotpl8 state'), work = path.join(dir, 'work'), home = path.join(dir, 'home');
  for (const made of [profile, state, work, home]) fs.mkdirSync(made, { recursive: true });
  const policy = JSON.parse(fs.readFileSync(path.join(root, 'policy.example.json'), 'utf8'));
  policy.prefer = [1, 2];
  fs.writeFileSync(path.join(state, 'policy.json'), JSON.stringify(policy));
  fs.writeFileSync(path.join(state, 'status.json'), snapshot(1, 1, [stamp(-600), stamp(-600)]));
  fs.writeFileSync(path.join(profile, '.credentials.json'), login('a'));

  // Nothing of the caller's session, profile or credentials reaches Claude or the hook.
  const env = {};
  for (const key of ['PATH', 'Path', 'SystemRoot', 'SYSTEMROOT', 'TEMP', 'TMP', 'TMPDIR', 'ComSpec', 'PATHEXT', 'windir', 'ProgramFiles', 'ProgramData',
    'OS', 'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'LANG']) if (process.env[key]) env[key] = process.env[key];
  Object.assign(env, { HOME: home, USERPROFILE: home, APPDATA: path.join(home, 'AppData', 'Roaming'), LOCALAPPDATA: path.join(home, 'AppData', 'Local'),
    CLAUDE_CONFIG_DIR: profile, ANTHROPIC_BASE_URL: 'http://127.0.0.1:' + server.address().port,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_AUTOUPDATER: '1', DISABLE_TELEMETRY: '1', CLAUDE_CODE_MAX_RETRIES: '0' });
  fs.mkdirSync(env.APPDATA, { recursive: true });
  fs.mkdirSync(env.LOCALAPPDATA, { recursive: true });

  const summary = { version: spawnSync(options.claude, ['--version'], { encoding: 'utf8', env }).stdout.trim(), sameAccount, managed };
  let child = null;
  try {
    const enable = { ...env };
    if (managed) {
      // A stand-in managed installation: the release holds what the waiter loads.
      const install = path.join(dir, 'managed install'), release = path.join(install, 'releases', 'fixture');
      fs.mkdirSync(release, { recursive: true });
      for (const item of ['continue.ps1', 'VERSION', 'src', 'data']) fs.cpSync(path.join(root, item), path.join(release, item), { recursive: true });
      fs.writeFileSync(path.join(install, 'current.json'), JSON.stringify({ protocol: 1, sha: 'fixture', release: 'releases/fixture' }));
      fs.writeFileSync(path.join(install, 'delivery.json'), JSON.stringify({ stateDirectory: state, powershell }));
      enable.HOTPL8_INSTALL_DIRECTORY = install;
    }
    const enabled = spawnSync(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'hotpl8.ps1'),
      'continue', '-Operation', 'enable', '-StateDirectory', state], { encoding: 'utf8', env: enable });
    summary.hookInstalled = enabled.status === 0 && enabled.stdout.includes('Claude hook: present');
    const hook = JSON.parse(fs.readFileSync(path.join(profile, 'settings.json'), 'utf8')).hooks.StopFailure[0].hooks[0];
    summary.hookForm = hook.args.includes('-Command') ? 'finds the current release' : 'fixed script';
    if (!summary.hookInstalled || (managed && summary.hookForm !== 'finds the current release')) throw new Error('hotpl8 continue did not install the expected hook');

    // The way an Agent SDK host runs Claude Code: streaming input, the session stays open.
    child = spawn(options.claude, ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
      '--setting-sources', 'user', '--permission-mode', 'bypassPermissions'], { cwd: work, env, stdio: ['pipe', 'pipe', 'ignore'] });
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: 'fixture start' }] }, parent_tool_use_id: null, session_id: '' }) + '\n');

    summary.limitHit = await until(() => requests.some(request => request.refused), 90);
    // The waiter reads which account is in use as it starts and then creates its record directory.
    summary.waiterStarted = await until(() => fs.existsSync(path.join(state, 'continue')), 120);
    await sleep(8000);
    summary.waitedQuietly = requests.length === 1 && child.exitCode === null;
    const limitedAt = Date.now();
    if (sameAccount) {
      limited.clear();
      replace(path.join(state, 'status.json'), snapshot(1, 1, [stamp(1), stamp(-600)]));
    } else {
      replace(path.join(profile, '.credentials.json'), login('b'));
      replace(path.join(state, 'status.json'), snapshot(2, 2, [stamp(-600), stamp(-600)]));
    }
    summary.continued = await until(() => requests.some(request => !request.refused && request.hasContinue), 120);
    summary.secondsToContinue = summary.continued ? Math.round((Date.now() - limitedAt) / 1000) : null;
    summary.answered = await until(() => (output.match(/"type":"result"/g) || []).length >= 2, 60);
    // Long enough for a second waiter to show itself if one continue could lead to another.
    await sleep(12000);
    summary.requests = requests;
    summary.events = fs.existsSync(path.join(state, 'events.jsonl'))
      ? fs.readFileSync(path.join(state, 'events.jsonl'), 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line).code) : [];
    const accepted = requests.filter(request => !request.refused);
    summary.passed = summary.limitHit && summary.waiterStarted && summary.waitedQuietly && summary.continued && summary.answered
      && requests.length === 2 && requests[0].refused && requests[0].account === 'a' && !requests[0].hasContinue
      && accepted.length === 1 && accepted[0].hasContinue && accepted[0].account === (sameAccount ? 'a' : 'b')
      && summary.events.filter(code => code === 'continue_sent').length === 1;
  } catch (error) {
    summary.failure = String(error.message);
    summary.requests = requests;
    summary.passed = false;
  } finally {
    if (child && child.exitCode === null) {
      child.stdin.end();
      if (!await until(() => child.exitCode !== null, 15)) child.kill();
    }
    server.close();
    server.closeAllConnections();
  }
  return [name, summary];
}

const scratch = fs.mkdtempSync(path.join(path.resolve(options.scratch), 'continue-'));
const result = {};
try {
  for (const [name, settings] of Object.entries({ 'different-account': {}, 'same-account-reset': { sameAccount: true }, 'managed-installation': { managed: true } })) {
    const [key, summary] = await run(name, path.join(scratch, name), settings);
    result[key] = summary;
  }
} finally {
  // A waiter that outlived its case ends once it sees Claude gone; give it that moment.
  await sleep(6000);
  fs.rmSync(scratch, { recursive: true, force: true, maxRetries: 10, retryDelay: 500 });
}
result.passed = Object.values(result).every(summary => summary.passed);
const text = JSON.stringify(result, null, 2) + '\n';
process.stdout.write(text);
if (options.output) fs.writeFileSync(options.output, text);
process.exit(result.passed ? 0 : 1);
