// Opt-in companion to probe-codex-rollover.py; never a production launcher.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { CodexBridge, readLines } from '../src/t3-codex.mjs';

const config = readFileSync(join(process.env.CODEX_HOME, 'config.toml'), 'utf8');
if (!/^openai_base_url = "http:\/\/127\.0\.0\.1:\d+\/v1"$/m.test(config) || !process.env.HOTPL8_FIXTURE_TOKENS) {
  throw new Error('This harness requires the isolated localhost Python fixture');
}
const tokens = JSON.parse(process.env.HOTPL8_FIXTURE_TOKENS);
let selected = 'a';
const child = spawn(process.argv[2], ['app-server'], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
const write = (stream, message) => stream.write(JSON.stringify(message) + '\n');
const bridge = new CodexBridge({
  cwd: process.cwd(),
  broker: async request => ({ slot: selected, home: process.env.CODEX_HOME, model: request.model || 'fixture-model', meter: 'codex',
    auth: { accessToken: tokens[selected], chatgptAccountId: `fixture-${selected}`, chatgptPlanType: 'plus' } }),
  toNative: message => write(child.stdin, message), toClient: message => write(process.stdout, message),
  onFatal: () => child.kill(), onRoutingError: code => { throw new Error(code); }
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
    selected = 'b';
    void bridge.observe().then(() => write(process.stdout, { id: message.id, result: { selected: bridge.route.slot } }));
  } else void bridge.client(message);
}, stop, stop);
child.on('exit', code => { bridge.close(); process.exitCode = code || 0; });
