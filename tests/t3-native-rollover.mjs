// Opt-in companion to probe-codex-rollover.py; never a production launcher.
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CodexBridge, readLines } from '../src/t3-codex.mjs';

const config = readFileSync(join(process.env.CODEX_HOME, 'config.toml'), 'utf8');
if (!/^openai_base_url = "http:\/\/127\.0\.0\.1:\d+\/v1"$/m.test(config) || !process.env.HOTPL8_FIXTURE_TOKENS) {
  throw new Error('This harness requires the isolated localhost Python fixture');
}
const tokens = JSON.parse(process.env.HOTPL8_FIXTURE_TOKENS);
const policyBroker = process.argv.includes('--policy-broker');
const brokerEvidence = { calls: 0, validatedSlots: [], routingErrors: [] };
const fixtureBroker = join(process.env.CODEX_HOME, 'fixture-policy-broker.ps1');
if (policyBroker) {
  // Fixture-only injection at the existing native quota Reader boundary. The
  // production broker still validates binding, transport, scope, quotas and
  // action controls and delegates the decision to the production shared core.
  writeFileSync(fixtureBroker, String.raw`param([string]$Root,[string]$FixtureHome,[string]$Executable)
$ErrorActionPreference='Stop'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    foreach($name in @('common','config','providers/claude','providers/codex','codex-routing')){. (Join-Path $Root ('src/'+$name+'.ps1'))}
    $request=[Console]::ReadLine()|ConvertFrom-Json
    $directory=Join-Path $FixtureHome 'fixture-routing'
    if($request.operation -eq 'fixture/init'){
        [void][IO.Directory]::CreateDirectory($directory)
        $now=[datetimeoffset]::UtcNow;$slots=@();$bindings=@{};$rows=@();$native=@{}
        foreach($id in @('a','b')){
            $accountHome=Join-Path $directory $id;[void][IO.Directory]::CreateDirectory($accountHome)
            $slots+=@{id=$id;home=$accountHome}
            $bindings[$id]=@{identityKey=('fixture-'+$id);binding=(Get-Hotpl8Hash ([IO.Path]::GetFullPath($accountHome)))}
            $quota=[pscustomobject]@{rateLimits=[pscustomobject]@{limitId='codex';primary=[pscustomobject]@{usedPercent=10;windowDurationMins=10080;resetsAt=$now.AddDays(3).ToUnixTimeSeconds()};secondary=$null;spendControlReached=$false;rateLimitReachedType=$null}}
            $native[$id]=$quota
            $rows+=@{id=$id;status='ok';observedAt=$now.ToString('o');defaultModel='fixture-model';buckets=(ConvertTo-CodexBuckets $quota $null $now)}
        }
        $policy=@{schemaVersion=2;mode='automate';switchEnabled=$true;warm=$false;probeEnabled=$false;prefer=@();codex=@{slots=$slots;prefer=@('a','b');order='prefer';defaultMeter='codex';modelMeters=@{'fixture-model'='codex'};margin7d=20;margin7dWork=5}}
        Write-Hotpl8Text (Join-Path $directory 'policy.json') ($policy|ConvertTo-Json -Depth 20)
        Write-Hotpl8Text (Join-Path $directory 'codex-state.json') (@{slots=$bindings}|ConvertTo-Json -Depth 10)
        Write-Hotpl8Text (Join-Path $directory 'status.json') (@{providers=@{codex=@{observedAt=$now.ToString('o');recommendations=@{codex='a'};slots=$rows}}}|ConvertTo-Json -Depth 20)
        Write-Hotpl8Text (Join-Path $directory 'fixture-quota.json') ($native|ConvertTo-Json -Depth 15)
        [Console]::WriteLine('{"initialized":true}');exit 0
    }
    if($request.operation -eq 'fixture/rollover'){
        $native=Read-Hotpl8Json (Join-Path $directory 'fixture-quota.json');$native.a.rateLimits.primary.usedPercent=96
        Write-Hotpl8Text (Join-Path $directory 'fixture-quota.json') ($native|ConvertTo-Json -Depth 15)
        $snapshot=Read-Hotpl8Json (Join-Path $directory 'status.json');$now=[datetimeoffset]::UtcNow
        foreach($row in $snapshot.providers.codex.slots){$row.observedAt=$now.ToString('o');$row.buckets=ConvertTo-CodexBuckets $native.($row.id) $row.buckets $now}
        $snapshot.providers.codex.observedAt=$now.ToString('o')
        Write-Hotpl8Text (Join-Path $directory 'status.json') ($snapshot|ConvertTo-Json -Depth 20)
        [Console]::WriteLine('{"published":true}');exit 0
    }
    $script:validated=@()
    $reader={param($slot,$refresh,$budget)
        $script:validated+= [string]$slot.id
        $native=Read-Hotpl8Json (Join-Path $directory 'fixture-quota.json')
        $tokens=$env:HOTPL8_FIXTURE_TOKENS|ConvertFrom-Json
        [pscustomobject]@{status='ok';identityKey=('fixture-'+$slot.id);standardTransport=$true;modelProvider='openai';model='fixture-model';quota=$native.($slot.id);auth=@{accessToken=$tokens.($slot.id);chatgptAccountId=('fixture-'+$slot.id);chatgptPlanType='plus'}}
    }
    $result=Get-Hotpl8CodexRoute $request $directory $Executable $reader
    $result|Add-Member NoteProperty fixtureEvidence @{validatedSlots=@($script:validated)}
    [Console]::WriteLine(($result|ConvertTo-Json -Depth 20 -Compress))
}catch{
    $code=[string]$_.Exception.Message
    if($code -notmatch '^routing_[a-z_]+$'){$code='fixture_broker_failed'}
    [Console]::WriteLine((@{error=$code}|ConvertTo-Json -Compress));exit 1
}
`, 'utf8');
}
const callPolicyBroker = request => new Promise((resolve, reject) => {
  const executable = process.platform === 'win32'
    ? join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe') : 'pwsh';
  const proc = spawn(executable, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', fixtureBroker,
    '-Root', fileURLToPath(new URL('../', import.meta.url)), '-FixtureHome', process.env.CODEX_HOME,
    '-Executable', process.argv[2]], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
  let output = '';
  const timeout = setTimeout(() => { proc.kill(); reject(new Error('fixture_broker_timeout')); }, 25000);
  proc.stdout.setEncoding('utf8'); proc.stdout.on('data', data => { output += data; });
  proc.on('error', err => { clearTimeout(timeout); reject(err); });
  proc.on('close', code => {
    clearTimeout(timeout);
    try {
      const result = JSON.parse(output.replace(/^\uFEFF/, ''));
      if (code || result.error) { const err = new Error(result.error || 'fixture_broker_failed'); err.code = err.message; reject(err); return; }
      if (result.fixtureEvidence) {
        brokerEvidence.calls++;
        brokerEvidence.validatedSlots.push(...result.fixtureEvidence.validatedSlots);
      }
      resolve(result);
    } catch { reject(new Error('fixture_broker_invalid_response')); }
  });
  proc.stdin.end(JSON.stringify(request) + '\n');
});
if (policyBroker) {
  try { await callPolicyBroker({ operation: 'fixture/init' }); }
  catch {
    // The Python client begins with initialize id1. Report a bounded fixture
    // startup error instead of making it wait for a response from a dead child.
    writeFileSync(1, JSON.stringify({ id: 1, error: { code: -32001, message: 'fixture_broker_initialization_failed' } }) + '\n');
    process.exit(1);
  }
}
let selected = 'a';
const child = spawn(process.argv[2], ['app-server'], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
const write = (stream, message) => stream.write(JSON.stringify(message) + '\n');
const bridge = new CodexBridge({
  cwd: process.cwd(),
  broker: policyBroker ? callPolicyBroker : async request => ({ slot: selected, home: process.env.CODEX_HOME, model: request.model || 'fixture-model', meter: 'codex',
    auth: { accessToken: tokens[selected], chatgptAccountId: `fixture-${selected}`, chatgptPlanType: 'plus' } }),
  toNative: message => write(child.stdin, message), toClient: message => write(process.stdout, message),
  onFatal: () => child.kill(), onRoutingError: code => { brokerEvidence.routingErrors.push(code); }
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
    void (async () => {
      if (policyBroker) await callPolicyBroker({ operation: 'fixture/rollover' });
      else selected = 'b';
      await bridge.observe();
      write(process.stdout, { id: message.id, result: { selected: bridge.route?.slot, policyBroker, ...brokerEvidence } });
    })().catch(() => write(process.stdout, { id: message.id, error: { code: -32001, message: 'fixture_rollover_failed' } }));
  } else void bridge.client(message);
}, stop, stop);
child.on('exit', code => { bridge.close(); process.exitCode = code || 0; });
