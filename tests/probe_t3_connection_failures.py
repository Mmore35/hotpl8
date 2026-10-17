"""Native composition: mismatch, rejected credentials, failed admission and cold upgrade."""
import importlib, json, pathlib, queue, subprocess, time
m=importlib.import_module('probe_t3_provider')
results=[]
def opened(home,shared):
    w=m.Wire(['node',str(m.CANDIDATE/'src/t3-codex.mjs'),'--bridge-config',str(home/'bridge-config.json'),'app-server','--stdio'],shared,home)
    return w
def initialize(w):
    return w.rpc('initialize',{'clientInfo':{'name':'t3_failure_fixture','version':'1'},'capabilities':{'experimentalApi':True}},time.monotonic()+15)
def descendants(pid):
    text=subprocess.check_output(['powershell','-NoProfile','-Command','Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId | ConvertTo-Json -Compress'],text=True)
    rows=json.loads(text); ids={pid}
    while True:
        new={r['ProcessId'] for r in rows if r['ParentProcessId'] in ids}
        if new.issubset(ids):return ids
        ids.update(new)
def cleanup(w):
    owned=descendants(w.proc.pid);w.close()
    remaining=set()
    for _ in range(3):
        text=subprocess.check_output(['powershell','-NoProfile','-Command','Get-CimInstance Win32_Process | Select-Object -ExpandProperty ProcessId | ConvertTo-Json -Compress'],text=True)
        remaining=owned.intersection(json.loads(text))
        if not remaining:break
        time.sleep(.3)
    assert not remaining, 'test process tree leaked'
    return len(owned)
try:
    home,account,shared=m.setup()
    state_path=home/'codex-state.json'; saved=state_path.read_bytes()
    # Corrupt only the expected identity, leaving the genuine collector digest intact.
    state=json.loads(saved.decode('utf-8-sig'));state['slots']['a']['connection']['identity']='a'*64
    state_path.write_text(json.dumps(state),encoding='utf-8')
    w=opened(home,shared)
    try:
        try:initialize(w);raise AssertionError('mismatched identity accepted')
        except RuntimeError as e:assert 'routing_binding_changed' in str(e)
        results.append({'case':'native identity mismatch','outcome':'initialization refused','cleanedProcesses':cleanup(w)})
    finally:state_path.write_bytes(saved)
    # Server denial after connection must never become a model request.
    w=opened(home,shared)
    try:
        initialize(w)
        thread=w.rpc('thread/start',{'cwd':str(home),'approvalPolicy':'never','sandbox':'read-only'},time.monotonic()+15)['thread']['id']
        m.mode['deny']=True; start=len(m.requests)
        try:
            w.rpc('turn/start',{'threadId':thread,'input':[{'type':'text','text':'fictional test; must be refused','text_elements':[]}]},time.monotonic()+40)
            raise AssertionError('failed live admission accepted')
        except RuntimeError as e:assert 'routing_unavailable' in str(e), str(e)
        posts=[r for r in m.requests[start:] if r.get('method')=='POST' and '/responses' in r.get('path','')]
        assert not posts
        results.append({'case':'service rejects credential after connection','outcome':'turn refused by full admission','modelRequests':0,'cleanedProcesses':cleanup(w)})
    finally:m.mode['deny']=False
    # A legacy state has no receipt: an uncontended full read remains compatible.
    state=json.loads(saved.decode('utf-8-sig'));state['slots']['a'].pop('connection')
    state_path.write_text(json.dumps(state),encoding='utf-8')
    w=opened(home,shared); before=len(m.requests)
    try:
        initialize(w)
        reads=sum('/usage' in r.get('path','') for r in m.requests[before:])
        assert reads>0,'legacy state skipped full live validation'
        results.append({'case':'legacy state without receipt','outcome':'connected through full validation','usageReads':reads,'cleanedProcesses':cleanup(w)})
    finally:state_path.write_bytes(saved)
    # A cached receipt cannot hide an unavailable serving native account.
    m.mode['deny']=True;w=opened(home,shared)
    try:
        try:initialize(w);raise AssertionError('denied serving account accepted')
        except RuntimeError:pass
        results.append({'case':'serving native rejects credential during connection','outcome':'initialization refused','cleanedProcesses':cleanup(w)})
    finally:m.mode['deny']=False
    # A backend that stalls is still subject to the host's complete deadline.
    m.mode['delay']=13;w=opened(home,shared);start=time.monotonic()
    try:
        try:
            w.rpc('initialize',{'clientInfo':{'name':'t3_hung_fixture','version':'1'},'capabilities':{'experimentalApi':True}},start+10)
            raise AssertionError('hung native backend falsely reported ready')
        except queue.Empty:pass
        elapsed=round((time.monotonic()-start)*1000)
        results.append({'case':'hung serving backend','outcome':'host deadline without false readiness','elapsedMs':elapsed,'cleanedProcesses':cleanup(w)})
    finally:m.mode.pop('delay',None)
    assert not (shared/'auth.json').exists()
    report={'results':results,'realCredentials':False,'outboundConnections':0,'sharedAuthWritten':False}
    (m.ROOT/'failure-path-results.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
finally:m.server.shutdown();m.server.server_close()
