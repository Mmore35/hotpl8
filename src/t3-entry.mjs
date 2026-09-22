// Protocol-1 bootstrap copied outside immutable releases. Select ONCE per process;
// rollback uses the same current.json pointer, including pre-bootstrap releases.
import { readFileSync, realpathSync, mkdirSync, writeFileSync, renameSync, unlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const read = path => JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
const hash = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const fail = () => { throw Object.assign(new Error('routing_delivery_invalid'), { code: 'routing_delivery_invalid' }); };
export function selectRelease(config) {
  const root = realpathSync(config.deliveryRoot);
  const pointer = read(join(root, 'current.json'));
  if (pointer.protocol !== 1 || !/^[a-f0-9]{40}$/.test(pointer.sha) || pointer.release !== `releases/${pointer.sha}`) fail();
  const release = join(root, 'releases', pointer.sha);
  if (realpathSync(release) !== release) fail();
  const receipt = read(join(root, 'receipts', `${pointer.sha}.json`));
  const manifestPath = join(release, 'delivery-manifest.json');
  if (hash(manifestPath) !== receipt.manifestDigest) fail();
  const manifest = read(manifestPath);
  const build = read(join(release, 'build-info.json'));
  if (manifest.product !== 'hotpl8' || manifest.sha !== pointer.sha || build.sha !== pointer.sha ||
      !manifest.files?.['src/t3-codex.mjs'] || !manifest.files?.['src/codex-route.ps1']) fail();
  for (const [name, expected] of Object.entries(manifest.files)) {
    if (name.includes('\\') || name.startsWith('/') || name.split('/').some(p => !p || p === '.' || p === '..')) fail();
    const path = join(release, name);
    if (!resolve(path).startsWith(release + '/') && !resolve(path).startsWith(release + '\\')) fail();
    if (realpathSync(path) !== path || hash(path) !== expected) fail();
  }
  return { sha: pointer.sha, script: join(release, 'src/t3-codex.mjs') };
}

function observe(configPath, sha) {
  const directory = join(dirname(configPath), 'processes');
  mkdirSync(directory, { recursive: true });
  const path = join(directory, `${process.pid}.json`);
  const startedAt = new Date(Date.now() - process.uptime() * 1000).toISOString();
  const update = () => {
    const temporary = path + '.tmp';
    writeFileSync(temporary, JSON.stringify({ schemaVersion: 1, pid: process.pid, sha, startedAt, observedAt: new Date().toISOString() }));
    renameSync(temporary, path);
  };
  update();
  const timer = setInterval(() => { try { update(); } catch { /* stale heartbeat is reported as unknown */ } }, 30000);
  timer.unref();
  process.on('exit', () => { try { unlinkSync(path); } catch {} });
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    if (process.argv[2] !== '--bridge-config') fail();
    const path = resolve(process.argv[3]);
    const config = read(path);
    if (config.schemaVersion !== 1 || !config.codex || !config.sharedHome || !config.stateDirectory || !config.powershell) fail();
    const selected = selectRelease(config);
    if (process.argv[4] === '--delivery-probe' && process.argv.length === 5) {
      // Read-only readiness, no native provider or account access.
      const bridge = await import(pathToFileURL(selected.script).href);
      if (typeof bridge.main !== 'function') fail();
      process.stdout.write(JSON.stringify({ sha: selected.sha }) + '\n');
    } else {
      observe(path, selected.sha);
      const bridge = await import(pathToFileURL(selected.script).href);
      await bridge.main(config, process.argv.slice(4));
    }
  } catch (error) {
    process.stderr.write(`HotPl8: ${/^routing_[a-z_]+$/.test(error.code) ? error.code : 'routing_delivery_invalid'}\n`);
    process.exitCode = 1;
  }
}
