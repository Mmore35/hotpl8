// Proves the client reads the short login URL before the native process exits.
// Output mirrors Claude Code 2.1.287 with piped stdio: it opens a browser itself,
// prints a fallback link, then waits on stdin for the code that link's page shows.
import fs from 'node:fs';
import path from 'node:path';
const profile = process.env.CLAUDE_CONFIG_DIR;
const fixture = JSON.parse(fs.readFileSync(path.join(profile, 'fixture.json'), 'utf8'));
const startsPath = path.join(profile, 'fixture-starts');
const starts = (fs.existsSync(startsPath) ? Number(fs.readFileSync(startsPath, 'utf8')) : 0) + 1;
fs.writeFileSync(startsPath, String(starts));
const url = 'https://claude.com/cai/oauth/authorize?fixture=' + starts;
// A pipe read may split the URL anywhere; only publish a complete handoff.
process.stdout.write('Opening browser to sign in…\nIf the browser didn\'t open, visit: ' + url.slice(0, -1));
setTimeout(() => process.stdout.write(url.slice(-1) + '\nPaste code here if prompted > '), 400);
function fail(detail) {
  fs.writeFileSync(path.join(profile, 'fixture-failure.json'), JSON.stringify(detail));
  process.exit(1);
}
function complete() {
  fs.writeFileSync(path.join(profile, 'fixture-auth-completed'), 'synthetic success');
  process.exit(0);
}
// Bound a live handoff, allowing slow shared Windows runners to service the pipe.
const deadline = Date.now() + 15000;
const timer = setInterval(() => {
  try {
    const operation = JSON.parse(fs.readFileSync(fixture.operationPath, 'utf8'));
    if (operation.handoff?.url === url && operation.handoff?.kind === 'paste_code') {
      clearInterval(timer);
      if (!fixture.paste) complete();
      // Stand in for submit_code; the worker must relay it through the open stdin.
      fs.writeFileSync(fixture.operationPath + '.code', 'fixture-code-' + starts + '#state\n');
      let input = '';
      process.stdin.setEncoding('utf8');
      process.stdin.on('data', (chunk) => {
        input += chunk;
        if (!input.includes('\n')) return;
        const code = input.split('\n')[0].trim();
        fs.writeFileSync(path.join(profile, 'fixture-code-' + starts), code);
        if (fixture.paste === 'reject-once' && starts === 1) {
          process.stderr.write('Login failed: Request failed with status code 400\n');
          process.exit(1);
        }
        if (code !== 'fixture-code-' + starts + '#state') fail({ reason: 'code_mismatch' });
        complete();
      });
      process.stdin.on('end', () => fail({ reason: 'stdin_closed' }));
      setTimeout(() => fail({ reason: 'code_timeout' }), 15000);
      return;
    }
    if (Date.now() >= deadline) {
      clearInterval(timer);
      fail({ reason: 'handoff_timeout', phase: operation.phase, handoff: operation.handoff });
    }
  } catch (error) {
    // Windows briefly locks the operation file while it is atomically replaced.
    if (['EBUSY', 'EPERM', 'EACCES'].includes(error.code) && Date.now() < deadline) return;
    clearInterval(timer);
    fail({ reason: 'fixture_read', code: error.code, message: error.message });
  }
}, 20);
