"""Unmodified production broker/bridge and real Codex; localhost TLS fixture only."""
import base64, ctypes, hashlib, http.server, json, os, pathlib, queue, shutil, ssl, subprocess, tempfile, threading, time
import argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--codex',type=pathlib.Path,required=True,help='Native Codex executable; never a real home')
parser.add_argument('--baseline',type=pathlib.Path,required=True,help='Unchanged release checkout with bin/windows reader')
parser.add_argument('--candidate',type=pathlib.Path,default=pathlib.Path(__file__).resolve().parents[1])
parser.add_argument('--scratch',type=pathlib.Path,required=True,help='Dedicated scratch directory for fictional accounts and evidence')
parser.add_argument('--openssl',default=shutil.which('openssl'),help='OpenSSL executable for a process-local test CA')
args=parser.parse_args()
if os.name != 'nt':parser.error('This contention qualification uses a real Windows exclusive file handle')
if not args.openssl:parser.error('Name the existing OpenSSL executable with --openssl')
ROOT=args.scratch.resolve();ROOT.mkdir(parents=True,exist_ok=True)
EXE=args.codex.resolve();BASELINE=args.baseline.resolve();CANDIDATE=args.candidate.resolve()
OPENSSL=args.openssl
PWSH=str(pathlib.Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/powershell.exe')
TLS = pathlib.Path(tempfile.mkdtemp(prefix='tls-fixture-',dir=ROOT))
if not (TLS/'leaf.pem').exists():
    def openssl(*args):subprocess.run([OPENSSL,*map(str,args)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    openssl('req','-x509','-newkey','rsa:2048','-nodes','-keyout',TLS/'ca.key','-out',TLS/'ca.pem','-days','2','-subj','/CN=HotPl8 isolated test CA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign')
    openssl('req','-new','-newkey','rsa:2048','-nodes','-keyout',TLS/'leaf.key','-out',TLS/'leaf.csr','-subj','/CN=chatgpt.com')
    (TLS/'leaf.ext').write_text('subjectAltName=DNS:chatgpt.com,DNS:api.openai.com\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
    openssl('x509','-req','-in',TLS/'leaf.csr','-CA',TLS/'ca.pem','-CAkey',TLS/'ca.key','-CAcreateserial','-out',TLS/'leaf.pem','-days','2','-extfile',TLS/'leaf.ext')
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(TLS/'leaf.pem',TLS/'leaf.key')
requests=[]; mode={'deny':False}
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_): pass
    def do_CONNECT(self):
        requests.append({'method':'CONNECT','path':self.path})
        # This proxy never opens an outbound socket, for any destination.
        self.send_response(200); self.end_headers()
        try:
            self.connection=context.wrap_socket(self.connection,server_side=True)
            self.rfile=self.connection.makefile('rb'); self.wfile=self.connection.makefile('wb')
            self.close_connection=False
        except (ssl.SSLError,ConnectionError) as exc:
            requests.append({'tlsError':str(exc)}); self.close_connection=True
    def respond(self,code,payload):
        raw=json.dumps(payload).encode(); self.send_response(code)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers()
        try:self.wfile.write(raw); self.wfile.flush()
        except (ConnectionError,ssl.SSLError):pass
    def do_POST(self):
        requests.append({'method':'POST','path':self.path})
        self.close_connection=True; self.respond(401,{'error':'fictional fixture refuses all writes'})
    def do_GET(self):
        requests.append({'method':'GET','path':self.path})
        if mode.get('delay'):time.sleep(mode['delay'])
        if mode['deny']: self.respond(401,{'error':'fictional expired credential'}); return
        if '/accounts/check' in self.path:
            self.respond(200,{'accounts':[{'id':'fixture-account','workspace_backend_origin':'https://chatgpt.com','account_routing_override':'NO_CONSTRAINT'}]})
        elif '/usage' in self.path:
            self.respond(200,{'plan_type':'pro','spend_control':{'reached':False},'rate_limit':{'allowed':True,'limit_reached':False,'primary_window':{'used_percent':10,'limit_window_seconds':604800,'reset_after_seconds':3600,'reset_at':int(time.time())+3600}},'code_review_rate_limit':None,'credits':None})
        elif '/models' in self.path:self.respond(200,{'models':[]})
        else:self.respond(503,{})
class Server(http.server.ThreadingHTTPServer):
    daemon_threads=True
    def handle_error(self,*_):pass
server=Server(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
proxy=f'http://127.0.0.1:{server.server_port}'
def b64(obj):return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('=')
token=b64({'alg':'none'})+'.'+b64({'email':'fixture@example.invalid','sub':'fixture-user','exp':4102444800,'https://api.openai.com/auth':{'chatgpt_account_id':'fixture-account','chatgpt_user_id':'fixture-user','chatgpt_plan_type':'pro'}})+'.fixture'
env={k:v for k,v in os.environ.items() if not k.startswith(('OPENAI_','CODEX_','ANTHROPIC_'))}
for k in ['HTTP_PROXY','HTTPS_PROXY','ALL_PROXY']:env[k]=proxy
env['NO_PROXY']='127.0.0.1,localhost'
env['CODEX_CA_CERTIFICATE']=env['SSL_CERT_FILE']=str(TLS/'ca.pem')

class Wire:
    def __init__(self,args,home,cwd):
        e=env.copy()
        for k in ['HOME','USERPROFILE','APPDATA','LOCALAPPDATA']:e[k]=str(home)
        self.proc=subprocess.Popen(args,cwd=cwd,env=e,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',creationflags=subprocess.CREATE_NO_WINDOW)
        self.q=queue.Queue(); self.sequence=0; self.timings=[]; self.start=time.monotonic()
        def drain():
            for line in self.proc.stdout:
                try:self.q.put(json.loads(line))
                except ValueError:pass
        threading.Thread(target=drain,daemon=True).start()
    def send(self,method,params):
        self.sequence+=1
        self.proc.stdin.write(json.dumps({'id':self.sequence,'method':method,'params':params})+'\n');self.proc.stdin.flush()
        return self.sequence
    def answer(self,id,deadline):
        while True:
            r=self.q.get(timeout=max(.001,deadline-time.monotonic()))
            if r.get('id')==id:return r
    def rpc(self,method,params,deadline):
        t=time.monotonic(); r=self.answer(self.send(method,params),deadline)
        self.timings.append({'method':method,'ms':round((time.monotonic()-t)*1000),'ok':'result' in r})
        if 'error' in r:raise RuntimeError(method+': '+json.dumps(r['error']))
        return r['result']
    def close(self):
        self.proc.stdin.close()
        try:self.proc.wait(5)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill','/PID',str(self.proc.pid),'/T','/F'],capture_output=True);self.proc.wait(5)

def lock(home):
    path=pathlib.Path(tempfile.gettempdir())/('hotpl8-codex-'+hashlib.sha256(str(home).lower().encode()).hexdigest()+'.lock')
    dll=ctypes.WinDLL('kernel32',use_last_error=True)
    dll.CreateFileW.restype=ctypes.c_void_p
    dll.CreateFileW.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p]
    handle=dll.CreateFileW(str(path),0xC0000000,0,None,4,0x80,None)
    assert handle != ctypes.c_void_p(-1).value,ctypes.get_last_error()
    dll.CloseHandle.argtypes=[ctypes.c_void_p]
    return lambda:dll.CloseHandle(handle)

def setup():
    home=pathlib.Path(tempfile.mkdtemp(prefix='whole-fixture-',dir=ROOT))
    account=home/'account'; account.mkdir(exist_ok=True)
    shared=home/'shared'; shared.mkdir(exist_ok=True)
    for d in [account,shared]:
        (d/'config.toml').write_text('approval_policy = "never"\n',encoding='utf-8')
    (account/'auth.json').write_text(json.dumps({'auth_mode':'chatgpt','OPENAI_API_KEY':None,'tokens':{'id_token':token,'access_token':token,'refresh_token':'fictional-refresh','account_id':'fixture-account'},'last_refresh':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}),encoding='utf-8')
    policy={'schemaVersion':2,'mode':'monitor','prefer':[],'codex':{'slots':[{'id':'a','home':str(account),'label':'Fictional'}],'prefer':['a'],'reserve':[],'order':'prefer','defaultMeter':'codex','margin7d':20,'margin7dWork':5}}
    (home/'policy.json').write_text(json.dumps(policy),encoding='utf-8')
    config={'schemaVersion':1,'codex':str(EXE),'sharedHome':str(shared),'stateDirectory':str(home),'powershell':PWSH}
    (home/'bridge-config.json').write_text(json.dumps(config),encoding='utf-8')
    e=env.copy()
    for k in ['HOME','USERPROFILE','APPDATA','LOCALAPPDATA']:e[k]=str(shared)
    candidate=CANDIDATE
    t=time.monotonic()
    p=subprocess.run([str(candidate/'bin/windows/hotpl8-native.exe'),'collect','--root',str(candidate),'--state',str(home),'--codex',str(EXE),'--observe-only','--strict'],env=e,capture_output=True,text=True,timeout=50)
    state=json.loads((home/'codex-state.json').read_text(encoding='utf-8-sig')) if (home/'codex-state.json').exists() else {}
    status=json.loads((home/'status.json').read_text(encoding='utf-8-sig')) if (home/'status.json').exists() else {}
    receipt=state.get('slots',{}).get('a',{}).get('connection')
    print(json.dumps({'collectorExit':p.returncode,'collectorMs':round((time.monotonic()-t)*1000),'receiptCreated':bool(receipt),'status':status.get('providers',{}).get('codex',{}).get('slots',[]),'http':requests}),flush=True)
    assert receipt,'production collector did not create receipt'
    return home,account,shared

def probe(revision,home,account,shared,held,usage):
    release=lock(account) if held else lambda:None
    timer=threading.Timer(13,release) if held else None
    if timer:timer.start()
    wire=Wire(['node',str((BASELINE if revision=='source' else CANDIDATE)/'src/t3-codex.mjs'),'--bridge-config',str(home/'bridge-config.json'),'app-server','--stdio'],shared,home)
    result={'revision':revision,'heldHomeLockMs':13000 if held else 0,'includeUsage':usage}
    try:
        deadline=wire.start+10
        wire.rpc('initialize',{'clientInfo':{'name':'t3_probe_fixture','version':'0.1'},'capabilities':{'experimentalApi':True}},deadline)
        wire.proc.stdin.write('{"method":"initialized"}\n');wire.proc.stdin.flush()
        acct=wire.rpc('account/read',{'refreshToken':False},deadline)
        assert acct['account']['type']=='chatgpt' and acct['account']['email']=='fixture@example.invalid'
        ids=[(wire.send('skills/list',{'cwds':[str(home)]}),'skills'),(wire.send('model/list',{'limit':2}),'models')]
        if usage:ids.append((wire.send('account/rateLimits/read',{}),'usage'))
        # Parallel responses may arrive in either order; collect by ID without discarding.
        answers={}
        while len(answers)<len(ids):
            r=wire.q.get(timeout=max(.001,deadline-time.monotonic()))
            if any(i==r.get('id') for i,_ in ids):answers[r['id']]=r
        for i,name in ids:
            if 'error' in answers[i]:raise RuntimeError(name+' failed')
        models=answers[ids[1][0]]['result']; count=len(models['data']); pages=1
        while models.get('nextCursor'):
            models=wire.rpc('model/list',{'limit':2,'cursor':models['nextCursor']},deadline)
            count+=len(models['data']);pages+=1
        assert count>0
        result.update(outcome='ready',modelCount=count,modelPages=pages,identityMatched=True)
    except queue.Empty:result['outcome']='timeout at T3 10-second deadline'
    except Exception as exc:result.update(outcome='error',error=str(exc))
    finally:
        result['elapsedMs']=round((time.monotonic()-wire.start)*1000)
        result['timings']=wire.timings
        wire.close()
        if timer:timer.join()
        result['bridgeExited']=wire.proc.poll() is not None
    print(json.dumps(result),flush=True)
    return result

if __name__=='__main__':
    try:
        home,account,shared=setup()
        results=[]
        for revision,held,usage in [('source',False,False),('source',True,False),('candidate',True,False),('candidate',True,True),('candidate',True,False)]:
            results.append(probe(revision,home,account,shared,held,usage))
        assert results[0]['outcome']=='ready', results[0]
        assert results[1]['outcome']=='timeout at T3 10-second deadline', results[1]
        assert all(r['outcome']=='ready' and r['elapsedMs']<10000 for r in results[2:]), results[2:]
        report={'nativeVersion':subprocess.check_output([str(EXE),'--version'],text=True).strip(),'results':results,'http':requests,'realCredentials':False,'outboundConnections':0,'sharedAuthWritten':(shared/'auth.json').exists()}
        (ROOT/'whole-path-results.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    finally:server.shutdown();server.server_close()
