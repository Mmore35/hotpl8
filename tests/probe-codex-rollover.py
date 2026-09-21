"""Opt-in installed Codex qualification with synthetic auth and localhost only.

Never uses a real credential home or model service. Dynamic tool calls are
answered by this fixture and perform no work. This is not billing qualification.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import struct
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def token(account):
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    return '.'.join([part({'alg': 'none'}), part({
        'sub': 'fixture-user', 'exp': int(time.time()) + 3600,
        'https://api.openai.com/auth': {
            'chatgpt_account_id': account, 'chatgpt_plan_type': 'plus'
        }
    }), 'fixture'])


def run(executable, scratch, transport, bridge):
    release = threading.Event()
    arrived = threading.Event()
    requests = []
    tokens = {name: token('fixture-' + name) for name in ['a', 'b']}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()

            def emit(event):
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()
            self.respond(body, emit, 'http')

        def do_GET(self):
            if transport != 'websocket' or self.headers.get('Upgrade', '').lower() != 'websocket':
                self.send_error(426)
                return
            key = self.headers.get('Sec-WebSocket-Key', '')
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.send_header('x-codex-turn-state', 'fixture-state-' + (self.headers.get('ChatGPT-Account-Id') or 'unknown'))
            self.end_headers()
            self.close_connection = True
            self.connection.settimeout(30)

            def emit(event):
                data = json.dumps(event).encode()
                header = bytes([0x81, len(data)]) if len(data) < 126 else bytes([0x81, 126]) + struct.pack('!H', len(data))
                self.wfile.write(header + data)
                self.wfile.flush()

            try:
                while True:
                    header = self.rfile.read(2)
                    if len(header) != 2 or header[0] & 15 == 8:
                        return
                    length = header[1] & 127
                    if length == 126:
                        length = struct.unpack('!H', self.rfile.read(2))[0]
                    elif length == 127:
                        length = struct.unpack('!Q', self.rfile.read(8))[0]
                    if length > 1024 * 1024:
                        raise ValueError('Oversized fixture websocket frame')
                    mask = self.rfile.read(4) if header[1] & 128 else None
                    body = self.rfile.read(length)
                    if mask:
                        body = bytes(b ^ mask[i % 4] for i, b in enumerate(body))
                    if header[0] & 15 == 1:
                        self.respond(body, emit, 'websocket')
            except (OSError, ValueError):
                return

        def respond(self, body, emit, received_transport):
            authorization = self.headers.get('Authorization', '')
            account = next((k for k, v in tokens.items() if authorization == 'Bearer ' + v), 'unknown')
            payload = json.loads(body)
            # Native websocket prewarming does not execute a model request.
            if payload.get('generate') is False:
                emit({'type': 'response.created', 'response': {'id': 'warmup', 'status': 'in_progress'}})
                emit({'type': 'response.completed', 'response': {'id': 'warmup', 'status': 'completed', 'output': []}})
                return
            requests.append({'account': account,
                             'accountHeader': self.headers.get('ChatGPT-Account-Id'),
                             'path': self.path, 'bytes': len(body), 'transport': received_transport,
                             'turnState': self.headers.get('x-codex-turn-state'),
                             'previousResponseId': payload.get('previous_response_id'),
                             'containsFollowup': 'fixture followup' in json.dumps(payload.get('input', [])),
                             'inputTypes': [i.get('type') for i in payload.get('input', [])]})
            n = len(requests)
            try:
                emit({'type': 'response.created', 'response': {'id': f'resp-{n}', 'status': 'in_progress'}})
                if n == 1:
                    arrived.set()
                    release.wait(25)
                    item = {'type': 'function_call', 'id': 'fc-fixture',
                            'call_id': 'call-fixture', 'name': 'fixture_step', 'arguments': '{}'}
                else:
                    item = {'type': 'message', 'id': f'msg-{n}', 'role': 'assistant',
                            'status': 'completed', 'content': [{'type': 'output_text', 'text': 'fixture done', 'annotations': []}]}
                emit({'type': 'response.output_item.added', 'output_index': 0, 'item': item})
                emit({'type': 'response.output_item.done', 'output_index': 0, 'item': item})
                emit({'type': 'response.completed', 'response': {
                    'id': f'resp-{n}', 'status': 'completed', 'output': [item],
                    'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}
                }})
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    events = []
    responses = queue.Queue()
    write_lock = threading.Lock()
    proc = None
    summary = {'qualification': 'native external auth, synthetic localhost model', 'transport': transport, 'bridge': bridge,
               'version': subprocess.check_output([executable, '--version'], text=True).strip()}
    try:
        with tempfile.TemporaryDirectory(prefix='rollover-', dir=scratch, ignore_cleanup_errors=True) as td:
            home = Path(td)
            (home/'config.toml').write_text(f'''model = "fixture-model"
approval_policy = "never"
sandbox_mode = "read-only"
cli_auth_credentials_store = "ephemeral"
openai_base_url = "http://127.0.0.1:{server.server_port}/v1"
[features]
enable_request_compression = false
''', encoding='utf-8')
            env = dict(os.environ)
            for key in ['OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'CODEX_SQLITE_HOME', 'OPENAI_BASE_URL', 'CODEX_HOME']:
                env.pop(key, None)
            env['CODEX_HOME'] = str(home)
            env['TEMP'] = env['TMP'] = str(home)
            command = [executable, 'app-server']
            if bridge:
                env['HOTPL8_FIXTURE_TOKENS'] = json.dumps(tokens)
                command = ['node', str(Path(__file__).with_name('t3-native-rollover.mjs')), executable]
            proc = subprocess.Popen(command, cwd=home, env=env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    text=True, encoding='utf-8',
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))

            def write(msg):
                with write_lock:
                    proc.stdin.write(json.dumps(msg) + '\n')
                    proc.stdin.flush()

            def reader():
                for line in proc.stdout:
                    msg = json.loads(line)
                    if 'id' in msg and 'method' not in msg:
                        responses.put(msg)
                    elif msg.get('method') == 'item/tool/call':
                        events.append(msg)
                        write({'id': msg['id'], 'result': {
                            'contentItems': [{'type': 'inputText', 'text': 'fixture result'}], 'success': True
                        }})
                    else:
                        events.append(msg)

            threading.Thread(target=reader, daemon=True).start()
            counter = 0

            def rpc(method, params):
                nonlocal counter
                counter += 1
                write({'id': counter, 'method': method, 'params': params})
                msg = responses.get(timeout=20)
                if msg['id'] != counter:
                    raise RuntimeError('Unexpected native response correlation')
                if 'error' in msg:
                    raise RuntimeError(f'{method}: ' + json.dumps(msg['error']))
                return msg['result']

            rpc('initialize', {'clientInfo': {'name': 'hotpl8-offline-rollover-probe', 'version': '1'},
                               'capabilities': {'experimentalApi': True}})
            write({'method': 'initialized'})

            def login(account):
                return rpc('account/login/start', {'type': 'chatgptAuthTokens',
                    'accessToken': tokens[account], 'chatgptAccountId': 'fixture-' + account, 'chatgptPlanType': 'plus'})

            if not bridge:
                login('a')
            opened = rpc('thread/start', {'cwd': str(home), 'model': 'fixture-model', 'ephemeral': True,
                'dynamicTools': [{'name': 'fixture_step', 'description': 'Fixture step with no side effects',
                                  'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}}]})
            tid = opened['thread']['id']
            first = rpc('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': 'fixture start', 'text_elements': []}]})
            if not arrived.wait(15):
                raise RuntimeError('No localhost model request received')
            summary['initial_request_account'] = requests[0]['account']
            followup = rpc('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': 'fixture followup', 'text_elements': []}]})
            summary['followup_same_turn'] = followup['turn']['id'] == first['turn']['id']
            summary['login_b_response'] = rpc('fixture/rollover', {}) if bridge else login('b')
            summary['completed_before_release'] = sum(e.get('method') == 'turn/completed' for e in events)
            release.set()
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and not any(e.get('method') == 'turn/completed' for e in events):
                time.sleep(.05)
            completed = [e for e in events if e.get('method') == 'turn/completed']
            summary['requests'] = requests
            summary['turn_started_count'] = sum(e.get('method') == 'turn/started' for e in events)
            summary['dynamic_tool_calls'] = sum(e.get('method') == 'item/tool/call' for e in events)
            summary['completion_statuses'] = [e['params']['turn']['status'] for e in completed]
            summary['same_turn_completed'] = bool(completed) and all(e['params']['turn']['id'] == first['turn']['id'] for e in completed)
            summary['native_error_messages'] = [e.get('params', {}).get('error', {}).get('message') for e in events if e.get('method') == 'error']
            summary['passed'] = (
                [r['account'] for r in requests] == ['a', 'b'] and
                summary['turn_started_count'] == 1 and summary['dynamic_tool_calls'] == 1 and
                summary['completion_statuses'] == ['completed'] and summary['same_turn_completed'] and
                summary['completed_before_release'] == 0
                and all(r['transport'] == transport for r in requests)
                and requests[1]['previousResponseId'] is None
                and summary['followup_same_turn'] and requests[1]['containsFollowup']
                and requests[1]['turnState'] != 'fixture-state-fixture-a'
            )
            if not completed:
                rpc('turn/interrupt', {'threadId': tid, 'turnId': first['turn']['id']})
            proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
    except Exception as exc:
        summary['failure'] = str(exc)
        summary['passed'] = False
        summary['requests'] = requests
        summary['event_methods'] = sorted(set(e.get('method', '') for e in events))
    finally:
        release.set()
        if proc and proc.poll() is None:
            proc.kill(); proc.wait()
        server.shutdown(); server.server_close()
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', required=True, help='Reviewed installed native binary')
    parser.add_argument('--scratch', required=True, type=Path, help='Existing disposable fixture parent')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--transport', choices=['http', 'websocket'], default='http')
    parser.add_argument('--bridge', action='store_true', help='Qualify the production dispatcher with a synthetic broker')
    args = parser.parse_args()
    result = run(args.codex, args.scratch.resolve(), args.transport, args.bridge)
    text = json.dumps(result, indent=2) + '\n'
    print(text, end='')
    if args.output:
        args.output.write_text(text, encoding='utf-8')
    raise SystemExit(0 if result.get('passed') else 1)
