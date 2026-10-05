"""Opt-in installed Codex qualification for automatic continue; synthetic auth and localhost only.

After a turn dies on a usage limit, does the installed Codex app-server accept a
new "Automated message: continue." turn on the same thread? Three cases: a
different account is signed in first, the same account's limit has reset, and
the limit lands in the middle of the work. Never uses a real credential home or
model service; the dynamic tool call is answered here and performs no work.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def token(account):
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    return '.'.join([part({'alg': 'none'}), part({
        'sub': 'fixture-user', 'exp': int(time.time()) + 3600,
        'https://api.openai.com/auth': {'chatgpt_account_id': account, 'chatgpt_plan_type': 'plus'}
    }), 'fixture'])


def run(executable, scratch, same_account, tool_first):
    requests = []
    tokens = {name: token('fixture-' + name) for name in ['a', 'b']}
    limited = {'a'}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_error(426)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            authorization = self.headers.get('Authorization', '')
            account = next((k for k, v in tokens.items() if authorization == 'Bearer ' + v), 'unknown')
            payload = json.loads(body)
            text = json.dumps(payload.get('input', []))
            n = len(requests) + 1
            # With --tool-first the limited account serves one tool-call step before
            # the limit lands, so the turn dies mid-work rather than at its start.
            serve_tool = tool_first and account in limited and not any(r['account'] == account for r in requests)
            refused = account in limited and not serve_tool
            requests.append({'n': n, 'account': account, 'path': self.path, 'refused': refused,
                             'inputTypes': [i.get('type') for i in payload.get('input', [])],
                             'hasOriginal': 'fixture start' in text, 'hasContinue': 'Automated message: continue.' in text,
                             'hasToolOutput': 'fixture result' in text})
            if refused:
                data = json.dumps({'error': {'type': 'usage_limit_reached', 'message': 'The usage limit has been reached',
                                             'plan_type': 'plus', 'resets_at': int(time.time()) + 3600,
                                             'resets_in_seconds': 3600}}).encode()
                self.send_response(429)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()

            def emit(event):
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                self.wfile.flush()
            if serve_tool:
                item = {'type': 'function_call', 'id': 'fc-fixture', 'call_id': 'call-fixture', 'name': 'fixture_step', 'arguments': '{}'}
            else:
                item = {'type': 'message', 'id': f'msg-{n}', 'role': 'assistant', 'status': 'completed',
                        'content': [{'type': 'output_text', 'text': 'fixture done', 'annotations': []}]}
            try:
                emit({'type': 'response.created', 'response': {'id': f'resp-{n}', 'status': 'in_progress'}})
                emit({'type': 'response.output_item.added', 'output_index': 0, 'item': item})
                emit({'type': 'response.output_item.done', 'output_index': 0, 'item': item})
                emit({'type': 'response.completed', 'response': {'id': f'resp-{n}', 'status': 'completed', 'output': [item],
                                                                 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}})
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    events = []
    responses = queue.Queue()
    lock = threading.Lock()
    proc = None
    summary = {'version': subprocess.check_output([executable, '--version'], text=True).strip(), 'sameAccount': same_account, 'toolFirst': tool_first}
    try:
        with tempfile.TemporaryDirectory(prefix='continue-', dir=scratch, ignore_cleanup_errors=True) as td:
            home = Path(td)
            (home / 'config.toml').write_text(f'''model = "fixture-model"
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
            proc = subprocess.Popen([executable, 'app-server'], cwd=home, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, encoding='utf-8',
                                    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))

            def write(msg):
                with lock:
                    proc.stdin.write(json.dumps(msg) + '\n')
                    proc.stdin.flush()

            def reader():
                for line in proc.stdout:
                    msg = json.loads(line)
                    if 'id' in msg and 'method' not in msg:
                        responses.put(msg)
                    elif msg.get('method') == 'item/tool/call':
                        events.append(msg)
                        write({'id': msg['id'], 'result': {'contentItems': [{'type': 'inputText', 'text': 'fixture result'}], 'success': True}})
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
                    raise RuntimeError('Unexpected response correlation')
                if 'error' in msg:
                    raise RuntimeError(f'{method}: ' + json.dumps(msg['error']))
                return msg['result']

            def login(account):
                return rpc('account/login/start', {'type': 'chatgptAuthTokens', 'accessToken': tokens[account],
                                                   'chatgptAccountId': 'fixture-' + account, 'chatgptPlanType': 'plus'})

            def completions():
                return [e for e in events if e.get('method') == 'turn/completed']

            def wait_completions(count, seconds=25):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline and len(completions()) < count:
                    time.sleep(.05)
                return len(completions()) >= count

            rpc('initialize', {'clientInfo': {'name': 'hotpl8-continue-probe', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
            write({'method': 'initialized'})
            login('a')
            tid = rpc('thread/start', {'cwd': str(home), 'model': 'fixture-model', 'ephemeral': True,
                'dynamicTools': [{'name': 'fixture_step', 'description': 'Fixture step with no side effects',
                                  'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}}]})['thread']['id']
            first = rpc('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': 'fixture start', 'text_elements': []}]})
            summary['firstCompleted'] = wait_completions(1)
            failed = completions()[0]['params'] if completions() else None
            summary['firstTurn'] = failed['turn'] if failed else None
            summary['eventsAfterFirst'] = [e.get('method') for e in events]
            marker = len(events)
            if not same_account:
                summary['loginB'] = login('b')
            else:
                limited.clear()  # the same account's limit reset
            second = rpc('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': 'Automated message: continue.', 'text_elements': []}]})
            summary['secondAccepted'] = second
            summary['secondCompleted'] = wait_completions(2)
            done = completions()[1]['params']['turn'] if len(completions()) > 1 else None
            summary['secondTurn'] = {k: done.get(k) for k in ['id', 'status', 'error']} if done else None
            summary['newTurnId'] = bool(done) and done['id'] != first['turn']['id']
            summary['eventsAfterSecond'] = [e.get('method') for e in events[marker:]]
            summary['requests'] = requests
            last = requests[-1] if requests else {}
            summary['passed'] = bool(
                failed and failed['turn'].get('status') == 'failed'
                and (failed['turn'].get('error') or {}).get('codexErrorInfo') == 'usageLimitExceeded'
                and done and done.get('status') == 'completed' and summary['newTurnId']
                and last.get('account') == ('a' if same_account else 'b')
                and not last.get('refused') and last.get('hasContinue'))
            proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
    except Exception as exc:
        summary['failure'] = str(exc)
        summary['passed'] = False
        summary['requests'] = requests
        summary['eventMethods'] = [e.get('method') for e in events]
    finally:
        if proc and proc.poll() is None:
            proc.kill(); proc.wait()
        server.shutdown(); server.server_close()
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', required=True, help='Reviewed installed native binary')
    parser.add_argument('--scratch', required=True, type=Path, help='Existing disposable fixture parent')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    cases = {'different-account': (False, False), 'same-account-reset': (True, False), 'limit-mid-work': (False, True)}
    result = {name: run(args.codex, args.scratch.resolve(), same, tool) for name, (same, tool) in cases.items()}
    result['passed'] = all(case.get('passed') for case in result.values())
    text = json.dumps(result, indent=2) + '\n'
    print(text, end='')
    if args.output:
        args.output.write_text(text, encoding='utf-8')
    raise SystemExit(0 if result['passed'] else 1)
