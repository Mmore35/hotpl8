// Proves the client reads the short login URL before the native process exits.
// Output mirrors Claude Code 2.1.287 with piped stdio: it prints a link whose page
// shows a code, then reads stdin line by line. A line without `code#state` only
// reports "Invalid code" and keeps waiting; a refused code ends the login.
import fs from 'node:fs';
import path from 'node:path';
const profile = process.env.CLAUDE_CONFIG_DIR;
const fixture = JSON.parse(fs.readFileSync(path.join(profile, 'fixture.json'), 'utf8'));
const startsPath = path.join(profile, 'fixture-starts');
const starts = (fs.existsSync(startsPath) ? Number(fs.readFileSync(startsPath, 'utf8')) : 0) + 1;
fs.writeFileSync(startsPath, String(starts));
function fail(detail) {
  fs.writeFileSync(path.join(profile, 'fixture-failure.json'), JSON.stringify(detail));
  process.exit(1);
}
function complete() {
  fs.writeFileSync(path.join(profile, 'fixture-auth-completed'), 'synthetic success');
  process.exit(0);
}
// Claude would open its own background tab through BROWSER; HotPl8 must disable it.
if (!process.env.BROWSER || !path.isAbsolute(process.env.BROWSER) || fs.existsSync(process.env.BROWSER)) {
  fail({ reason: 'browser_not_suppressed' });
}
const url = 'https://claude.com/cai/oauth/authorize?fixture=' + starts;
const good = 'fixture-code-' + starts + '#state';
// A pipe read may split the URL anywhere; only publish a complete handoff.
process.stdout.write('Opening browser to sign in…\nIf the browser didn\'t open, visit: ' + url.slice(0, -1));
setTimeout(() => process.stdout.write(url.slice(-1) + '\nPaste code here if prompted > '), 400);
function readOperation() {
  try {
    return JSON.parse(fs.readFileSync(fixture.operationPath, 'utf8'));
  } catch (error) {
    // Windows briefly locks the operation file while it is atomically replaced,
    // and between the two renames of that replacement the name is absent. A file
    // that never comes back still ends in the caller's bounded wait.
    if (['EBUSY', 'EPERM', 'EACCES', 'ENOENT'].includes(error.code) || error instanceof SyntaxError) return null;
    fail({ reason: 'fixture_read', code: error.code, message: error.message });
  }
}
// Stand in for submit_code; the worker must relay it through the open stdin.
function submit(code) {
  fs.writeFileSync(fixture.operationPath + '.code', code + '\n');
}
function waitFor(test, reason, then) {
  // Bounded for slow shared Windows runners.
  const deadline = Date.now() + 15000;
  const timer = setInterval(() => {
    const operation = readOperation();
    if (operation && test(operation)) {
      clearInterval(timer);
      then(operation);
    } else if (Date.now() >= deadline) {
      clearInterval(timer);
      fail({ reason, phase: operation?.phase, handoff: operation?.handoff });
    }
  }, 20);
}
waitFor((op) => op.handoff?.url === url && op.handoff?.kind === 'paste_code', 'handoff_timeout', (operation) => {
  fs.writeFileSync(path.join(profile, 'fixture-message-' + starts), operation.message);
  if (!fixture.paste) complete();
  const incomplete = fixture.paste === 'incomplete-once' && starts === 1;
  submit(incomplete ? 'fixture-code-' + starts : good);
  const lines = [];
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    input += chunk;
    let end;
    while ((end = input.indexOf('\n')) >= 0) {
      const line = input.slice(0, end).trim();
      input = input.slice(end + 1);
      lines.push(line);
      fs.writeFileSync(path.join(profile, 'fixture-code-' + starts), lines.join('\n'));
      const [code, state] = line.split('#');
      if (!code || !state) {
        process.stderr.write('Invalid code. Please make sure the full code was copied.\n');
        // The worker must accept another code once Claude reports the bad one.
        waitFor((op) => op.handoff?.codeReceived === false && /incomplete/.test(op.message), 'invalid_code_not_reopened', (op) => {
          fs.writeFileSync(path.join(profile, 'fixture-reopened-message'), op.message);
          submit(good);
        });
        continue;
      }
      if (fixture.paste === 'reject-once' && starts === 1) {
        process.stderr.write('Login failed: Request failed with status code 400\n');
        process.exit(1);
      }
      if (line !== good) fail({ reason: 'code_mismatch' });
      complete();
    }
  });
  process.stdin.on('end', () => fail({ reason: 'stdin_closed' }));
  setTimeout(() => fail({ reason: 'code_timeout' }), 30000);
});
