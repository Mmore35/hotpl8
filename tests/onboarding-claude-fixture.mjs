// Proves the client reads the short login URL before the native process exits.
import fs from 'node:fs';
import path from 'node:path';
const profile = process.env.CLAUDE_CONFIG_DIR;
const fixture = JSON.parse(fs.readFileSync(path.join(profile, 'fixture.json'), 'utf8'));
process.stdout.write('https://claude.ai/oauth/authorize?fixture=true\n');
const deadline = Date.now() + 3000;
const timer = setInterval(() => {
  try {
  const operation = JSON.parse(fs.readFileSync(fixture.operationPath, 'utf8'));
  if (operation.handoff?.url === 'https://claude.ai/oauth/authorize?fixture=true') {
    fs.writeFileSync(path.join(profile, 'fixture-auth-completed'), 'synthetic success');
    clearInterval(timer);
    process.exit(0);
  }
  if (Date.now() >= deadline) {
    fs.writeFileSync(path.join(profile, 'fixture-failure.json'), JSON.stringify({ reason: 'handoff_timeout', phase: operation.phase, handoff: operation.handoff }));
    clearInterval(timer); process.exit(1);
  }
  } catch (error) {
    fs.writeFileSync(path.join(profile, 'fixture-failure.json'), JSON.stringify({ reason: 'fixture_read', code: error.code, message: error.message }));
    clearInterval(timer); process.exit(1);
  }
}, 20);
