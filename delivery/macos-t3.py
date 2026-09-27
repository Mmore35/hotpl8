"""Mac T3 enrollment: ordinary Codex, shared home, one managed release pointer.

Settings are changed only by explicit host-closed activation/removal. Updates
replace an immutable bootstrap binding, never settings or existing processes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runner import DeliveryError, digest, lock, read, run, safe_root, write
from macos import atomic_bytes, executable, native_only, owned_config, selected


def closed(settings_path=None):
    processes = run(['/bin/ps', '-axo', 'pid=,command='], 10).decode('utf-8', 'replace')
    runtime = read(Path(settings_path).parent / 'server-runtime.json', {}) if settings_path else {}
    live_pid = runtime.get('pid') and re.search(r'^\s*' + re.escape(str(runtime['pid'])) + r'\s', processes, re.M)
    desktop = re.search(r'/[^\n/]*[Tt]3[^\n/]*\.app/Contents/', processes)
    standalone = re.search(r'^\s*\d+\s+(?:\S*/)?(?:node|bun|t3|t3code)\s+[^\n]*(?:server\.asar|/apps/server/|/@t3tools/|/t3code/|/t3/|\bt3(?:code)?\.(?:mjs|cjs|js)\b)', processes, re.M | re.I)
    if live_pid or desktop or standalone:
        raise DeliveryError('Quit T3 completely before changing its provider settings; active work was preserved')


def bindings(root):
    _, config = owned_config(root)
    for item in config.get('macosT3', []):
        if not re.fullmatch(r'[A-Za-z0-9_-]+', item.get('name', '')):
            raise DeliveryError('Invalid native T3 registration')
        directory = safe_root(root / 'integrations' / item['name'])
        receipt = read(directory / 'receipt.json')
        settings = read(item['settingsPath'])
        if settings is None:
            raise DeliveryError('Registered T3 settings are missing')
        instance = settings.get('providerInstances', {}).get('codex')
        connected = instance and instance.get('config', {}).get('binaryPath') == item['binaryPath']
        if not receipt:
            raise DeliveryError('Registered native T3 receipt is missing')
        if receipt.get('settingsPath') != item['settingsPath'] or receipt.get('installedInstance', {}).get('config', {}).get('binaryPath') != item['binaryPath']:
            raise DeliveryError('Native T3 receipt identity changed')
        if not connected:
            yield directory, receipt, None
            continue
        if instance != receipt['installedInstance']:
            raise DeliveryError('T3 provider settings changed; reconcile ownership before delivery')
        bridge = read(directory / 'bridge-config.json', {})
        if (bridge.get('schemaVersion') != 1 or bridge.get('deliveryRoot') != str(root)
                or bridge.get('stateDirectory') != config['stateDirectory']):
            raise DeliveryError('Native T3 state binding changed')
        for key in ('node', 'codex', 'powershell'):
            executable(bridge.get(key))
        for path, expected in receipt['ownedFiles'].items():
            candidate = directory / path
            if Path(path).name != path or candidate.is_symlink() or digest(candidate) != expected:
                raise DeliveryError('Native T3 launcher ownership changed')
        if not Path(bridge['sharedHome']).is_dir() or digest(bridge['script']) != bridge.get('bootstrapDigest'):
            raise DeliveryError('Native T3 bootstrap or shared home is unavailable')
        yield directory, receipt, bridge


def bootstrap(directory, release, bridge):
    source = release / 'src/t3-entry.mjs'
    expected = digest(source)
    target = directory / ('entry-' + expected + '.mjs')
    if target.exists():
        if target.is_symlink() or digest(target) != expected:
            raise DeliveryError('Native T3 bootstrap changed')
    else:
        atomic_bytes(target, source.read_bytes())
    bridge.update(script=str(target), bootstrapDigest=expected)
    write(directory / 'bridge-config.json', bridge)


def reconcile(root, release, operation):
    for directory, receipt, bridge in bindings(root):
        if bridge is None:
            continue  # Deliberate provider removal is not undone by an update.
        if receipt['launcherDigest'] != digest(release / 'delivery/macos-t3-launch.py'):
            raise DeliveryError('Native T3 launcher requires an explicit compatibility migration')
        if operation in ('activate', 'recover'):
            with lock(directory / 'setup.lock'):
                bootstrap(directory, release, bridge)
        if operation in ('health', 'recover'):
            probe = json.loads(run([bridge['node'], bridge['script'], '--bridge-config', directory / 'bridge-config.json', '--delivery-probe'], 20))
            if probe.get('sha') != read(release / 'build-info.json')['sha']:
                raise DeliveryError('Native T3 selected release failed readiness')


def observations(directory, bridge):
    # Receipt alone cannot prove a live process. Match command, creation time
    # and fresh heartbeat; PID reuse/stale receipts never establish freshness.
    output = run(['/bin/ps', '-axo', 'pid=,lstart=,command='], 10).decode('utf-8', 'replace')
    running, unknown = set(), 0
    config_path = str(directory / 'bridge-config.json')
    for line in output.splitlines():
        match = re.match(r'\s*(\d+)\s+(.{24})\s+(.*)', line)
        if not match or config_path not in match[3] or '--bridge-config' not in match[3]:
            continue
        record = read(directory / 'processes' / (match[1] + '.json'), {})
        try:
            started = datetime.strptime(match[2], '%a %b %d %H:%M:%S %Y').astimezone()
            age = (datetime.now(timezone.utc) - datetime.fromisoformat(record['observedAt'].replace('Z', '+00:00'))).total_seconds()
            if (record['pid'] != int(match[1]) or not re.fullmatch(r'[a-f0-9]{40}', record['sha'])
                    or not 0 <= age < 90 or abs((started - datetime.fromisoformat(record['startedAt'].replace('Z', '+00:00'))).total_seconds()) >= 5):
                raise ValueError('stale')
            running.add(record['sha'])
        except (KeyError, ValueError, TypeError):
            unknown += 1
    return sorted(running), unknown


def components(root):
    current = read(root / 'current.json', {}).get('sha')
    result = []
    for directory, receipt, bridge in bindings(root):
        running, unknown = observations(directory, bridge) if bridge else ([], 0)
        state = ('unmanaged' if not bridge else 'running-version-unknown' if unknown
                 else 'restart-pending' if any(sha != current for sha in running) else 'current')
        result.append(dict(component='t3-codex', providerId='codex', state=state,
                           nextLaunchSha=current if bridge else None, runningShas=running,
                           unknownRunningProcesses=unknown, adoption='New provider processes; active work retained'))
    return result or [dict(component='t3-codex', providerId='codex', state='unmanaged',
                           nextLaunchSha=None, runningShas=[], unknownRunningProcesses=None,
                           adoption='No T3 bridge enrolled with this installation')]


def enroll(root, settings_path, node, codex, shared_home, activate=False):
    native_only()
    root, settings_path, shared_home = safe_root(root), safe_root(settings_path), safe_root(shared_home)
    _, config = owned_config(root)
    release = selected(root)
    directory = root / 'integrations' / 't3-codex'
    directory.mkdir(parents=True, exist_ok=True)
    with lock(root / 'update.lock'), lock(directory / 'setup.lock'):
        settings_bytes = settings_path.read_bytes()
        settings = json.loads(settings_bytes.decode('utf-8-sig'))
        if not isinstance(settings, dict) or not shared_home.is_dir():
            raise DeliveryError('Existing T3 settings and shared Codex home are required')
        receipt = read(directory / 'receipt.json')
        original = settings.get('providerInstances', {}).get('codex')
        if receipt is None:
            if settings.get('providers', {}).get('codex'):
                raise DeliveryError('Legacy explicit Codex settings need a separately inspected migration')
            if original and (original.get('driver') != 'codex' or original.get('config', {}).get('launchArgs') or original.get('config', {}).get('binaryPath')):
                raise DeliveryError('Existing custom Codex binding needs explicit reconciliation')
            configured_home = (original or {}).get('config', {}).get('homePath')
            if configured_home and Path(configured_home).expanduser().resolve() != shared_home.resolve():
                raise DeliveryError('Preserve the existing T3 conversation home')
            launcher = directory / 'hotpl8-codex'
            shim = ('#!/bin/sh\nexec ' + shlex.quote(config['python']) + ' '
                    + shlex.quote(str(directory / 'launch.py')) + ' '
                    + shlex.quote(str(directory / 'bridge-config.json')) + ' "$@"\n').encode()
            installed = json.loads(json.dumps(original or dict(driver='codex', config={})))
            installed.setdefault('config', {}).update(binaryPath=str(launcher), homePath=str(shared_home))
            receipt = dict(schemaVersion=1, phase='staged', settingsPath=str(settings_path),
                           originalInstance=original, installedInstance=installed,
                           launcherDigest=digest(release / 'delivery/macos-t3-launch.py'), ownedFiles={})
            for name, body in [('launch.py', (release / 'delivery/macos-t3-launch.py').read_bytes()), ('hotpl8-codex', shim)]:
                path = directory / name
                if path.exists() and path.read_bytes() != body:
                    raise DeliveryError('Existing native T3 launcher is not owned by this enrollment')
                atomic_bytes(path, body, 0o700)
                receipt['ownedFiles'][name] = hashlib.sha256(body).hexdigest()
            bridge = dict(schemaVersion=1, node=executable(node), codex=executable(codex),
                          powershell=config['powershell'], sharedHome=str(shared_home),
                          stateDirectory=config['stateDirectory'], deliveryRoot=str(root))
            bootstrap(directory, release, bridge)
            write(directory / 'receipt.json', receipt)
        if receipt['settingsPath'] != str(settings_path):
            raise DeliveryError('Integration belongs to another T3 settings file')
        # Register staging too: missing files remain visible instead of silently
        # dropping an installed component out of the updater's inventory.
        config['macosT3'] = [dict(name='t3-codex', settingsPath=str(settings_path),
                                  binaryPath=receipt['installedInstance']['config']['binaryPath'])]
        write(root / 'delivery.json', config)
        if not activate:
            return dict(state='staged', providerId='codex')
        closed(settings_path)
        if original not in (receipt['originalInstance'], receipt['installedInstance']):
            raise DeliveryError('T3 Codex settings changed after staging')
        bridge = read(directory / 'bridge-config.json')
        # Verify the complete selected release before committing a T3 binding.
        probe = json.loads(run([bridge['node'], bridge['script'], '--bridge-config', directory / 'bridge-config.json', '--delivery-probe'], 20))
        if probe.get('sha') != read(release / 'build-info.json')['sha']:
            raise DeliveryError('Native T3 staged release failed readiness')
        settings.setdefault('providerInstances', {})['codex'] = receipt['installedInstance']
        # The receipt precedes the settings commit; an interruption is retryable.
        if settings_path.read_bytes() != settings_bytes:
            raise DeliveryError('T3 settings changed concurrently')
        closed(settings_path)
        if not (directory / 'settings-before.json').exists():
            atomic_bytes(directory / 'settings-before.json', settings_bytes)
        write(settings_path, settings)
        receipt['phase'] = 'active'
        write(directory / 'receipt.json', receipt)
        reconcile(root, release, 'health')
        return dict(state='active', providerId='codex')


def remove(root):
    native_only()
    closed()
    with lock(root / 'update.lock'):
        for directory, receipt, bridge in bindings(root):
            if bridge is None:
                continue
            with lock(directory / 'setup.lock'):
                closed(receipt['settingsPath'])
                settings = read(receipt['settingsPath'])
                if settings.get('providerInstances', {}).get('codex') != receipt['installedInstance']:
                    raise DeliveryError('T3 settings changed; refusing removal')
                if receipt['originalInstance'] is None:
                    settings['providerInstances'].pop('codex')
                else:
                    settings['providerInstances']['codex'] = receipt['originalInstance']
                write(receipt['settingsPath'], settings)
                receipt['phase'] = 'removed'
                write(directory / 'receipt.json', receipt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['stage', 'activate', 'remove'])
    parser.add_argument('--install', required=True)
    parser.add_argument('--settings')
    parser.add_argument('--home')
    parser.add_argument('--node', default=shutil.which('node'))
    parser.add_argument('--codex')
    args = parser.parse_args()
    root = safe_root(args.install)
    try:
        if args.operation == 'remove':
            result = remove(root)
        else:
            if not args.settings or not args.home or not args.codex:
                raise DeliveryError('Specify settings, shared home and native Codex executable')
            result = enroll(root, args.settings, args.node, args.codex, args.home, args.operation == 'activate')
        print(json.dumps(result))
    except (DeliveryError, OSError, ValueError) as error:
        raise SystemExit(str(error) if isinstance(error, DeliveryError) else type(error).__name__)


if __name__ == '__main__':
    main()
