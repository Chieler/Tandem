import json, os, pathlib, select, sqlite3, subprocess, sys, time

binary, root = sys.argv[1:]
root = pathlib.Path(root)
socket = os.environ['TMUX'].rsplit(',', 2)[0]
env = os.environ.copy()
env['CNTCTR_TMUX'] = socket
passes = failures = 0

def check(label, condition):
    global passes, failures
    if condition: passes += 1
    else: failures += 1; print('FAIL:', label, flush=True)

def tmux(*args):
    return subprocess.check_output(['tmux','-S',socket,*args], text=True).strip()

def hook(harness, event, data, extra=None, keep_open=False):
    e=env.copy(); e.update(extra or {})
    p=subprocess.Popen([binary,'hook',harness,event],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=e)
    t=time.monotonic()
    if keep_open:
        ready,_,_=select.select([p.stdout],[],[],2.15)
        if not ready:
            p.kill(); p.communicate(); return None, None, time.monotonic()-t
        out=p.stdout.readline(); p.stdin.close(); p.wait(timeout=1)
    else:
        try: out,_=p.communicate(data,timeout=2.15)
        except subprocess.TimeoutExpired:
            p.kill(); p.communicate(); return None,None,time.monotonic()-t
    return p.returncode, out.strip(), time.monotonic()-t

def pane(name, command='cat'):
    v=tmux('new-window','-d','-n',name,'-P','-F','#{pane_id}',command)
    tmux('set','-p','-t',v,'@cntctr_name',name)
    tmux('set','-p','-t',v,'@cntctr_harness','claude')
    return v

def call(source, tool, arguments):
    e=env.copy();e['TMUX_PANE']=source;e.pop('CNTCTR_PANE',None)
    p=subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=e)
    def ask(n,method,params):
        p.stdin.write(json.dumps({'jsonrpc':'2.0','id':n,'method':method,'params':params})+'\n');p.stdin.flush()
        while True:
            r=json.loads(p.stdout.readline())
            if r.get('id') == n:return r
    ask(1,'initialize',{'protocolVersion':'2025-06-18','clientInfo':{'name':'test'}})
    r=ask(2,'tools/call',{'name':tool,'arguments':arguments})
    p.stdin.close();p.wait(timeout=5)
    return r

def response(h,e,data,extra=None,keep=False):
    rc,out,elapsed=hook(h,e,data,extra,keep)
    return rc==0 and out==b'{}' and elapsed<2.0

bad={'CNTCTR_DB':str(root/'missing'/'db')}
check('U3 broken store neutral', response('claude','SessionStart',b'{"session_id":"s"}',{**bad, 'CNTCTR_PANE':'%0'}))
check('U3 empty stdin neutral', response('claude','SessionStart',b''))
check('U3 never-closed stdin neutral within 2 s', response('claude','SessionStart',b'',keep=True))
check('U3 invalid JSON neutral', response('claude','unknown',b'not json'))
malformed=str(root/'malformed.db')
check('U3 trailing junk neutral',response('claude','SessionStart',b'{"session_id":"s"}junk',{'CNTCTR_DB':malformed,'CNTCTR_PANE':'%0'}))
if pathlib.Path(malformed).exists():
    d=sqlite3.connect(malformed)
    try: bogus=d.execute('select count(*) from hook_sessions').fetchone()[0]
    except sqlite3.Error: bogus=0
    d.close()
else: bogus=0
check('U3 trailing junk records no session',bogus==0)
locked=str(root/'locked.db'); db=sqlite3.connect(locked);db.execute('create table x(n)');db.commit();db.execute('begin exclusive')
check('U3 locked store neutral within 2 s',response('claude','SessionStart',b'{"session_id":"s"}',{'CNTCTR_DB':locked,'CNTCTR_PANE':'%0'}))
db.rollback();db.close()

legacy=str(root/'legacy.db'); db=sqlite3.connect(legacy)
db.executescript("create table mail(post integer primary key,name text not null,pane text not null,delivered integer not null default 0); insert into mail values(1,'old','%1',0);");db.commit();db.close()
target=pane('hook_claude')
env['CNTCTR_DB']=legacy;env['CNTCTR_PANE']=target
fixture=pathlib.Path('fixtures/hooks/claude-SessionStart.json').read_bytes()
check('U3 valid event neutral',response('claude','SessionStart',fixture))
db=sqlite3.connect(legacy)
try:
    cols={r[1] for r in db.execute('pragma table_info(mail)')}
    check('U3 old mail migrated as pending',{'state','staged_turn','presentations'}<=cols and db.execute('select state from mail where post=1').fetchone()==('pending',))
except sqlite3.Error: check('U3 old mail migrated as pending',False)
try:
    hcols={r[1] for r in db.execute('pragma table_info(hook_sessions)')}
    check('U3 session schema includes wake reservation',{'socket','pane','harness','session_id','harness_pid','last_event','at','prompt_seen','stop_seen','wake_reserved','wake_at'}<=hcols)
except sqlite3.Error: check('U3 session schema includes wake reservation',False)
db.execute("update mail set state='staged', staged_turn='turn-1', presentations=2 where post=1");db.commit();db.close()
check('U3 reopening migrated store remains neutral',response('claude','SessionStart',fixture))
db=sqlite3.connect(legacy); row=db.execute('select delivered,state,staged_turn,presentations from mail where post=1').fetchone(); db.close()
check('U3 migration preserves existing mail state on reopen',row==(0,'staged','turn-1',2))

check('U4 codex hook neutral',response('codex','Stop',pathlib.Path('fixtures/hooks/claude-Stop.json').read_bytes()))
db=sqlite3.connect(legacy)
try: n=db.execute("select count(*) from hook_sessions where harness='codex'").fetchone()[0]
except sqlite3.Error:n=-1
db.close();check('U4 codex records no session',n==0)
home=pathlib.Path(env['HOME'])
def files(): return {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
home_before=files()
p=subprocess.run([binary,'hooks','install','codex'],input=b'',stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=3)
check('U4 codex hook install refused',p.returncode!=0)
check('U4 codex hook install changes no file',files()==home_before)

# A live executable named claude remains the parent of every hook command.
source=root/'claude.c';source.write_text(r"""
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc,char **argv) {
 char event[128],path[4096];
 while (scanf("%127s %4095s",event,path)==2) {
   pid_t child=fork();
   if (!child) { if (!freopen(path,"r",stdin)) _exit(2); execl(argv[1],argv[1],"hook",argv[2],event,(char*)0); _exit(127); }
   int st; waitpid(child,&st,0); puts("DONE"); fflush(stdout);
 }
 return 0;
}
""")
launcher=str(root/'claude');subprocess.run(['cc','-o',launcher,str(source)],check=True)
parent=subprocess.Popen([launcher,binary,'claude'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=env)
def emit(event, filename):
    parent.stdin.write(event+' '+str(pathlib.Path('fixtures/hooks',filename).resolve())+'\n');parent.stdin.flush()
    line=parent.stdout.readline().strip();done=parent.stdout.readline().strip()
    return line=='{}' and done=='DONE'
def status():
    p=subprocess.run([binary,'hook','status',target],input=b'',stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=3)
    return p.stdout.decode().strip().lower()
check('U5 session-start accepted',emit('SessionStart','claude-SessionStart.json'))
check('U5 start alone has no hooks',status()=='no')
check('U5 prompt accepted',emit('UserPromptSubmit','claude-UserPromptSubmit-mail.json'))
check('U5 prompt without stop has no hooks',status()=='no')
check('U5 stop accepted',emit('Stop','claude-Stop.json'))
check('U5 prompt and stop establish hooks',status()=='yes')
db=sqlite3.connect(legacy)
db.execute("update hook_sessions set harness_pid=? where pane=?",(os.getpid(),target));db.commit();db.close()
check('U5 unrelated live process cannot stand in for harness',status()=='no')
db=sqlite3.connect(legacy)
db.execute("update hook_sessions set harness_pid=? where pane=?",(parent.pid,target));db.commit();db.close()
new_session=root/'new-session.json'; data=json.loads(fixture); data['session_id']='SESSION-2'; new_session.write_text(json.dumps(data))
check('U5 new session-start resets event evidence',emit('SessionStart',str(new_session)) and status()=='no')
db=sqlite3.connect(legacy); row=db.execute('select session_id,count(*) from hook_sessions where pane=?',(target,)).fetchone(); db.close()
check('U5 new session replaces old pane row',row==('SESSION-2',1))
check('U5 hooks reestablished',emit('SessionStart','claude-SessionStart.json') and emit('UserPromptSubmit','claude-UserPromptSubmit-mail.json') and emit('Stop','claude-Stop.json') and status()=='yes')
parent.stdin.close(); time.sleep(.2)
check('U5 exited unreaped harness has no hooks',status()=='no')
parent.wait(timeout=3)
check('U5 dead harness has no hooks',status()=='no')
# Background Claude hooks can recover the pane from the live ancestor's session.
sessions=root/'claude-sessions'; sessions.mkdir()
fallback_env=env.copy(); fallback_env.pop('CNTCTR_PANE',None); fallback_env.pop('TMUX_PANE',None)
fallback_env['CNTCTR_CLAUDE_SESSIONS_DIR']=str(sessions)
parent=subprocess.Popen([launcher,binary,'claude'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=fallback_env)
(sessions/(str(parent.pid)+'.json')).write_text(json.dumps({'tmux':'cntctr:@1.'+target}))
check('U5 background session hook accepted',emit('SessionStart',str(new_session)))
db=sqlite3.connect(legacy); row=db.execute('select session_id,harness_pid from hook_sessions where pane=?',(target,)).fetchone(); db.close()
check('U5 background hook records session via live Claude ancestor',row==('SESSION-2',parent.pid))
parent.stdin.close();parent.wait(timeout=3)
# A detached Claude process can recover the tmux socket from the session file too.
fallback_env.pop('TMUX',None); fallback_env.pop('CNTCTR_TMUX',None)
parent=subprocess.Popen([launcher,binary,'claude'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=fallback_env)
(sessions/(str(parent.pid)+'.json')).write_text(json.dumps({'tmux':pathlib.Path(socket).name+':@1.'+target}))
check('U5 detached session hook accepted',emit('SessionStart',str(new_session)))
db=sqlite3.connect(legacy); row=db.execute('select session_id,harness_pid from hook_sessions where socket=? and pane=?',(socket,target)).fetchone(); db.close()
check('U5 detached hook recovers socket and pane',row==('SESSION-2',parent.pid))
parent.stdin.close();parent.wait(timeout=3)
# An explicit pane can coexist with a socket that only the session file knows.
fallback_env['CNTCTR_PANE']=target
new_session_data=json.loads(fixture);new_session_data['session_id']='SESSION-3';new_session.write_text(json.dumps(new_session_data))
parent=subprocess.Popen([launcher,binary,'claude'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=fallback_env)
(sessions/(str(parent.pid)+'.json')).write_text(json.dumps({'tmux':pathlib.Path(socket).name+':@1.'+target}))
check('U5 explicit pane detached hook accepted',emit('SessionStart',str(new_session)))
db=sqlite3.connect(legacy); row=db.execute('select session_id,harness_pid from hook_sessions where socket=? and pane=?',(socket,target)).fetchone(); db.close()
check('U5 explicit pane recovers missing socket',row==('SESSION-3',parent.pid))
parent.stdin.close();parent.wait(timeout=3)
# Both recorded events are required for agy as well.
agy_launcher=str(root/'agy');subprocess.run(['cc','-o',agy_launcher,str(source)],check=True)
parent=subprocess.Popen([agy_launcher,binary,'agy'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=env)
check('U5 agy prompt accepted',emit('PreInvocation','agy-PreInvocation-first.json'))
check('U5 agy prompt alone has no hooks',status()=='no')
check('U5 agy stop accepted',emit('Stop','agy-Stop.json'))
check('U5 agy prompt and stop establish hooks',status()=='yes')
tmux('kill-pane','-t',target)
check('U5 dead pane has no hooks',status()=='no')
parent.stdin.close();parent.wait(timeout=3)

# Delivery stays off: hooked and codex panes still receive full envelopes.
raw=root/'raw.py';raw.write_text("import os,sys,tty\ntty.setraw(0)\nos.write(1,b'\\x1b[?2004h')\nopen(sys.argv[1],'wb').close()\nwhile True:\n d=os.read(0,4096)\n if not d: break\n with open(sys.argv[1],'ab') as f: f.write(d)\n")
sender=pane('hook_sender')
for name in ('hook_codex','hook_partial'):
    log=root/(name+'.log'); target2=pane(name, 'python3 '+str(raw)+' '+str(log))
    tmux('set','-p','-t',target2,'@cntctr_harness','codex' if name=='hook_codex' else 'claude')
    for _ in range(100):
        if log.exists() and tmux('display','-p','-t',target2,'#{bracket_paste_flag}')=='1':break
        time.sleep(.05)
    e=env.copy(); e['CNTCTR_PANE']=target2
    if name=='hook_partial': response('claude','SessionStart',fixture,{'CNTCTR_PANE':target2})
    result=call(sender,'send',{'to':name,'text':'complete envelope '+name})
    time.sleep(.2)
    data=log.read_bytes() if log.exists() else b''
    check(('U4' if name=='hook_codex' else 'U5')+' full envelope delivered',b'[cntctr from=' in data and ('complete envelope '+name).encode() in data and b'[cntctr end id=' in data and not result['result'].get('isError'))

cc=subprocess.run(['cc','-std=c11','-I.','-I/opt/homebrew/opt/json-c/include','-o',str(root/'hook-adapter-test'),'tests/hook_adapter_test.c','hooks.c','-L/opt/homebrew/opt/json-c/lib','-ljson-c'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
if cc.returncode:
    print('FAIL: adapter test build',cc.stderr.decode(),flush=True);failures+=1
else:
    result=subprocess.run([str(root/'hook-adapter-test')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    print(result.stdout,end='');
    if result.returncode: failures+=1;print(result.stderr,end='')
    else: passes+=13
print(f'{passes} passed, {failures} failed')
sys.exit(bool(failures))
