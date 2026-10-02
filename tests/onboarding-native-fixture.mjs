// Offline app-server fixture: only synthetic identity, no network or real credentials.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
const home = process.env.CODEX_HOME;
const fixture = JSON.parse(fs.readFileSync(path.join(home, 'fixture.json'), 'utf8'));
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const log = value => fs.appendFileSync(path.join(home, 'calls.jsonl'), JSON.stringify(value) + '\n');
let authenticated = fs.existsSync(path.join(home, 'auth.json'));
for await (const line of readline.createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  log(request.method);
  if (!Object.hasOwn(request, 'id')) continue;
  let result = {};
  switch (request.method) {
    case 'account/read':
      result = { account: authenticated ? { type: fixture.apiKey ? 'apiKey' : 'chatgpt', email: fixture.nullEmail ? null : 'fixture@example.invalid', planType: 'plus' } : null };
      break;
    case 'config/read': result = { config: { model_provider: 'openai', model_providers: {} } }; break;
    case 'account/rateLimits/read':
      if (fixture.quotaFailure) { send({ id: request.id, error: { code: 429, message: 'synthetic private detail' } }); continue; }
      result = { rateLimits: {} }; break;
    case 'account/login/start':
      result = request.params.type === 'chatgptDeviceCode'
        ? { type: 'chatgptDeviceCode', loginId: 'fixture-login', verificationUrl: 'https://auth.openai.com/codex/device', userCode: 'TEST-ONLY' }
        : { type: 'chatgpt', loginId: 'fixture-login', authUrl: 'https://auth.openai.com/fixture' };
      if (fixture.cancelPath) setTimeout(() => fs.writeFileSync(fixture.cancelPath, 'cancel'), 100);
      else setTimeout(() => {
        fs.writeFileSync(path.join(home, 'auth.json'), JSON.stringify({ tokens: { account_id: 'workspace-fixture' } }));
        authenticated = true;
        send({ method: 'account/login/completed', params: { loginId: 'fixture-login', success: true } });
      }, 100);
      break;
    case 'account/login/cancel': break;
    default: break;
  }
  send({ id: request.id, result });
}
