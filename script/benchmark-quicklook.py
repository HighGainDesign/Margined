#!/usr/bin/env python3
"""Measure actual system Quick Look through an explicit private benchmark host."""
from pathlib import Path
import argparse,ctypes,hashlib,importlib.util,json,math,os,plistlib,re,selectors,shutil,signal,statistics,subprocess,tempfile,time,types,uuid

SOURCE_ROOT=Path(__file__).resolve().parents[1]
HELPERS=SOURCE_ROOT/'Benchmarks/QuickLook'
HOST_ID='design.highgain.margined.benchmark.ql14'
PROVIDER_ID=HOST_ID+'.quicklook'
UTI=HOST_ID+'.document'
EXTENSION='marginedqlbench14'
WORDS='ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL INDIA JULIET KILO LIMA MIKE NOVEMBER OSCAR PAPA QUEBEC ROMEO SIERRA TANGO'.split()
s=importlib.util.spec_from_file_location('mobile_benchmark',SOURCE_ROOT/'script/benchmark-mobile.py')
M=importlib.util.module_from_spec(s);s.loader.exec_module(M)

def validate_metadata(host,provider):
    claims=[t for d in host.get('CFBundleDocumentTypes',[]) for t in d.get('LSItemContentTypes',[])]
    declarations=host.get('UTImportedTypeDeclarations',[])
    extension=provider.get('NSExtension',{});attributes=extension.get('NSExtensionAttributes',{})
    if (host.get('CFBundleIdentifier')!=HOST_ID or host.get('CFBundleExecutable')!='ScopeHost'
        or provider.get('CFBundleIdentifier')!=PROVIDER_ID or provider.get('CFBundleExecutable')!='MarginedQuickLook'
        or claims!=[UTI] or len(declarations)!=1 or declarations[0].get('UTTypeIdentifier')!=UTI
        or declarations[0].get('UTTypeTagSpecification',{}).get('public.filename-extension')!=[EXTENSION]
        or extension.get('NSExtensionPointIdentifier')!='com.apple.quicklook.preview'
        or attributes.get('QLIsDataBasedPreview') is not True or attributes.get('QLSupportedContentTypes')!=[UTI]):
        raise ValueError('Only the dedicated private host/type/provider may be registered')

def accepted_frame(row,word):
    return bool(re.search(r'\bPreview\s+'+re.escape(word)+r'\b',row.get('text',''),re.I)) and all(row.get('colors',{}).get(color,0)>1000 for color in ('green','blue'))

def summarize(rows,mode,count):
    if mode not in ('cold','warm') or type(count) is not int or not 1<=count<=20 or len(rows)!=count:
        raise ValueError('Incomplete Quick Look cohort')
    for index,row in enumerate(rows):
        if row.get('mode')!=mode or type(row.get('index')) is not int or row['index']!=index:
            raise ValueError('Incorrect or duplicate cohort index')
        if any(type(row.get(k)) is not int or row[k]<=0 for k in ('request_ns','observed_ns','hostPID','providerPID')) or row['observed_ns']<row['request_ns']:
            raise ValueError('Invalid process or clock bounds')
        events=row.get('events',[])
        if {e.get('stage') for e in events}!={'request','ready','deliver'}:
            raise ValueError('Missing actual provider stages')
        if any(e.get('pid')!=row['providerPID'] or type(e.get('uptime_ns')) is not int or not row['request_ns']<=e['uptime_ns']<=row['observed_ns'] for e in events):
            raise ValueError('Provider process/clock mismatch')
        stamps=[min(e['uptime_ns'] for e in events if e['stage']==stage) for stage in ('request','ready','deliver')]
        if stamps!=sorted(stamps):raise ValueError('Provider stages are out of order')
    for key in ('hostPID','providerPID'):
        if len({r[key] for r in rows})!=(count if mode=='cold' else 1):raise ValueError('Cold/warm process contract violated')
    values=[(r['observed_ns']-r['request_ns'])/1e6 for r in rows]
    return dict(count=count,median_ms=statistics.median(values),p95_ms=sorted(values)[math.ceil(count*.95)-1],maximum_ms=max(values))


class PrivateRegistration:
    def __init__(self,command,app,extension):
        self.command=command;self.app=app;self.extension=extension;self.attempted=False
    def open(self):
        self.attempted=True
        self.command([LSREGISTER,'-f',str(self.app)],'register-host')
        self.command(['pluginkit','-a',str(self.extension)],'register-extension')
        self.command(['pluginkit','-e','use','-i',PROVIDER_ID],'enable-extension')
    def close(self):
        if not self.attempted:return
        errors=[]
        for label,args in [('disable',['pluginkit','-e','default','-i',PROVIDER_ID]),('unregister-extension',['pluginkit','-r',str(self.extension)]),('unregister-host',[LSREGISTER,'-u',str(self.app)])]:
            try:self.command(args,label,cleanup=True)
            except BaseException as error:errors.append(repr(error))
        self.attempted=False
        if errors:raise RuntimeError('; '.join(errors))

LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'



def validate_output(output,source_root):
    output=output.resolve();source_root=source_root.resolve()
    if output.is_relative_to(source_root):
        relative=output.relative_to(source_root).as_posix()+'/'
        result=subprocess.run(['git','-C',str(source_root),'check-ignore','-q','--',relative],capture_output=True)
        if result.returncode!=0:
            raise ValueError('Report output must be outside the source checkout or in a gitignored directory')
    return output


def stage_runtime(original,recognize,fixtures,runtime):
    runtime.mkdir()
    shutil.copytree(original,runtime/'ScopeHost.app',symlinks=True)
    shutil.copy2(recognize,runtime/'recognize')
    shutil.copytree(fixtures,runtime/'fixtures')


class ConsoleGuard:
    def __init__(self):
        self.observations=0
        self.cg=ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        self.cf=ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.cg.CGSessionCopyCurrentDictionary.restype=ctypes.c_void_p
        self.cf.CFPropertyListCreateData.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_long,ctypes.c_ulong,ctypes.c_void_p]
        self.cf.CFPropertyListCreateData.restype=ctypes.c_void_p
        self.cf.CFDataGetLength.argtypes=[ctypes.c_void_p];self.cf.CFDataGetLength.restype=ctypes.c_long
        self.cf.CFDataGetBytePtr.argtypes=[ctypes.c_void_p];self.cf.CFDataGetBytePtr.restype=ctypes.c_void_p
        self.cf.CFRelease.argtypes=[ctypes.c_void_p]
    def unlocked(self):
        session=self.cg.CGSessionCopyCurrentDictionary()
        if not session:return False
        data=self.cf.CFPropertyListCreateData(None,session,100,0,None)
        try:
            if not data:return False
            info=plistlib.loads(ctypes.string_at(self.cf.CFDataGetBytePtr(data),self.cf.CFDataGetLength(data)));self.observations+=1
            return info.get('kCGSSessionOnConsoleKey') is True and info.get('kCGSessionLoginDoneKey') is True and not info.get('CGSSessionScreenIsLocked',False)
        finally:
            if data:self.cf.CFRelease(data)
            self.cf.CFRelease(session)

class ProcessIdentity:
    identity=staticmethod(M.identity)
    @staticmethod
    def matching(rows,paths):
        allowed={str(Path(p).resolve()) for p in paths};result=[]
        for row in rows:
            path=M.executable_path(row['pid'])
            if path and str(Path(path).resolve()) in allowed:result.append(dict(row,comm=path))
        return result

def execute(args):
    if not __debug__:raise RuntimeError('Run this developer harness without Python -O')
    original=args.host.resolve();recognize=args.recognize.resolve()
    validate_metadata(plistlib.loads((original/'Contents/Info.plist').read_bytes()),plistlib.loads((original/'Contents/PlugIns/MarginedQuickLook.appex/Contents/Info.plist').read_bytes()))
    M.run(['codesign','--verify','--deep','--strict',str(original)])
    OUT=validate_output(args.output,SOURCE_ROOT);OUT.mkdir(parents=True,exist_ok=False)
    RUNTIME=Path(tempfile.gettempdir())/('MarginedQL-'+str(uuid.uuid4()));APP=RUNTIME/'ScopeHost.app';EXT=APP/'Contents/PlugIns/MarginedQuickLook.appex';ID=PROVIDER_ID
    (OUT/'runtime.json').write_text(json.dumps(dict(path=str(RUNTIME),ownedByThisRun=True))+'\n')
    source=M.source_pin(SOURCE_ROOT);bundle=M.file_map(original);recognizeSHA=hashlib.sha256(recognize.read_bytes()).hexdigest()
    words=WORDS[:args.samples];fixtures=OUT/'fixtures';shutil.copytree(HELPERS/'fixtures',fixtures)
    text=(fixtures/'docs/template.md').read_text()
    for mode in ('cold','warm'):
        for i,word in enumerate(words):(fixtures/'docs'/f'{mode}-{i:02}.{EXTENSION}').write_text(text.replace('BASELINE',word))
    for name,word in [('functional.'+EXTENSION,'QUALIFY'),('unmeasured-baseline.'+EXTENSION,'BASELINE'),('negative-raw-source.txt','NEGATIVE')]:
        (fixtures/'docs'/name).write_text(text.replace('BASELINE',word))
    SHA=lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest()
    P=dict(hostFiles=bundle,recognizeSHA256=recognizeSHA,pins={},fixtures=str(fixtures),pixels=str(HELPERS/'pixels.py'),words=words)
    def sourceVerify():
        assert M.source_pin(SOURCE_ROOT)==source,'source_changed'
        assert M.file_map(original)==bundle and SHA(recognize)==recognizeSHA,'artifact_changed'
    C=types.SimpleNamespace(ROOT=SOURCE_ROOT,SHA=SHA,files=M.file_map,identity=M.identity,verify=sourceVerify,
        processes=lambda:[dict(pid=int(p)) for p in M.run(['/bin/ps','-axo','pid=']).split()])
    PID=ProcessIdentity
    C.own=lambda:PID.matching(C.processes(),[APP/'Contents/MacOS/ScopeHost',EXT/'Contents/MacOS/MarginedQuickLook'])
    ls='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    G=ConsoleGuard();start=time.monotonic();deadline=start+900;commands=[];hosts=[];owned=[];fail=None;samples=[];captures=[];log=None;census=[];nextPS=0
    def save(n,v):(OUT/n).write_text(json.dumps(v,indent=2)+'\n')
    def remember(process):
     stamp=C.identity(process.pid);owned.append((process,stamp))
     pending=OUT/'owned-processes.tmp'
     pending.write_text(json.dumps([dict(pid=p.pid,identity=identity) for p,identity in owned])+'\n')
     pending.replace(OUT/'owned-processes.json')
    def verify():
     C.verify()
     for n,h in P['pins'].items():assert C.SHA(Path(n))==h,n
     if APP.exists():
      assert C.files(APP)==P['hostFiles']
      assert C.SHA(RUNTIME/'recognize')==P['recognizeSHA256']
    def ownproviders():return PID.matching(C.processes(),[EXT/'Contents/MacOS/MarginedQuickLook'])
    def ownhostprocesses():
     return PID.matching(C.processes(),[APP/'Contents/MacOS/ScopeHost'])
    def check():
     nonlocal nextPS
     assert G.unlocked(),'console_locked_or_unknown'
     assert time.monotonic()<deadline,'original900seconddeadline'
     if time.monotonic()>=nextPS:
      census.append(dict(seconds=time.monotonic()-start,ownedProviders=ownproviders()))
      nextPS=time.monotonic()+5
    def command(args,label,limit=20,cleanup=False):
     if not cleanup:check()
     t=time.monotonic();end=t+limit
     with (OUT/(label+'.stdout')).open('x') as f,(OUT/(label+'.stderr')).open('x') as e:
      p=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=f,stderr=e,start_new_session=True);remember(p)
      try:
       while p.poll() is None:
        if not cleanup:check()
        assert time.monotonic()<end,'command_deadline:'+label
        time.sleep(.1)
      finally:
       if p.poll() is None:os.killpg(p.pid,signal.SIGTERM)
       try:p.wait(timeout=5)
       except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
      commands.append(dict(label=label,args=args,pid=p.pid,returncode=p.returncode,seconds=time.monotonic()-t))
     assert p.returncode==0,(label,p.returncode,(OUT/(label+'.stderr')).read_text()[-1000:])
     return (OUT/(label+'.stdout')).read_bytes()
    def handler(label,cleanup=False):
     code='ObjC.import("AppKit"); const u=$.NSURL.fileURLWithPath('+json.dumps(str(C.ROOT/'Fixtures/Rendering.md'))+');const a=$.NSWorkspace.sharedWorkspace.URLForApplicationToOpenURL(u);ObjC.unwrap(a.path);'
     return command(['osascript','-l','JavaScript','-e',code],label,cleanup=cleanup).decode().strip()
    def providerEvents(file):
     result=[]
     for line in (OUT/'system.ndjson').read_text(errors='replace').splitlines():
      try:
       row=json.loads(line);message=row.get('eventMessage','');prefix='MARGINED_QL_BENCH '
       if prefix not in message:continue
       value=json.loads(message.split(prefix,1)[1]);assert value['identifier']==ID
       if value['file']==file:result.append(value)
      except (json.JSONDecodeError,KeyError):continue
     return result
    class Host:
     def __init__(self,label):
      check();self.label=label;self.rows=[];self.buffer=b'';self.sel=selectors.DefaultSelector();self.window=None;self.closed=False;self.closedCleanly=False
      self.err=(OUT/(label+'-host.stderr')).open('x');self.p=subprocess.Popen([str(APP/'Contents/MacOS/ScopeHost')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.err,start_new_session=True);self.ident=C.identity(self.p.pid);remember(self.p);hosts.append(self)
      self.sel.register(self.p.stdout,selectors.EVENT_READ);end=time.monotonic()+15
      while self.window is None:
       check();assert time.monotonic()<end,'hostreadydeadline';self.pump()
      assert C.identity(self.p.pid)==self.ident
      command(['/usr/bin/open','-a',str(APP)],label+'-activate-owned-app',10)
      actual=ownhostprocesses();save(label+'-owned-after-activation.json',actual);assert {r['pid'] for r in actual}=={self.p.pid},('Activation must reuse the already owned host',actual,self.p.pid)
     def pump(self):
      assert self.p.poll() is None,'hostended'
      for key,_ in self.sel.select(.05):
       data=os.read(key.fileobj.fileno(),65536);assert data;self.buffer+=data
       while b'\n' in self.buffer:
        line,self.buffer=self.buffer.split(b'\n',1)
        row=json.loads(line);assert row['pid']==self.p.pid;self.rows.append(row)
        if row['phase']=='host-ready':self.window=row['window']
     def send(self,action,path=None):
      token=str(uuid.uuid4());value=dict(action=action,token=token)
      if path:value['path']=str(path)
      self.p.stdin.write((json.dumps(value)+'\n').encode());self.p.stdin.flush();return token
     def response(self,phase,token):
      end=time.monotonic()+5
      while True:
       check();self.pump();found=[x for x in self.rows if x['phase']==phase and x.get('token')==token]
       if found:return found[-1]
       assert time.monotonic()<end,'hostresponsedeadline'
     def status(self):
      end=time.monotonic()+5
      while True:
       check();row=self.response('status',self.send('status'))
       assert row['window']==self.window and row['contentWidth']==850 and row['contentHeight']==700 and row['scale']>0,row
       if all(row[k] is True for k in ['active','visible','onSpace','unoccluded']):return row
       assert time.monotonic()<end,('native_visibility_not_ready',row)
       time.sleep(.1)
     def close(self):
      if self.closed:return
      if self.p.poll() is None:
       try:self.send('close');self.p.wait(timeout=5)
       except BaseException:
        if self.p.poll() is None:os.killpg(self.p.pid,signal.SIGTERM)
        try:self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(self.p.pid,signal.SIGKILL);self.p.wait()
      self.buffer+=self.p.stdout.read()
      for line in self.buffer.splitlines():
       try:
        row=json.loads(line);assert row['pid']==self.p.pid;self.rows.append(row)
       except (json.JSONDecodeError,AssertionError):self.rows.append(dict(phase='invalid-termination-receipt'))
      self.buffer=b'';self.sel.close();self.err.close();self.closed=True
      self.closedCleanly=self.p.returncode==0 and sum(r.get('phase')=='closing' for r in self.rows)==1 and sum(r.get('phase')=='will-terminate' for r in self.rows)==1
      save(self.label+'-host.json',dict(pid=self.p.pid,identity=self.ident,returncode=self.p.returncode,closedCleanly=self.closedCleanly,rows=self.rows))
    def stopExtraHosts():
     rows=ownhostprocesses();seen=[]
     for r in rows:
      ident=C.identity(r['pid']);seen.append(dict(pid=r['pid'],identity=ident,comm=r['comm']))
      if ident:os.kill(r['pid'],signal.SIGTERM)
     end=time.monotonic()+5
     while ownhostprocesses() and time.monotonic()<end:time.sleep(.1)
     for r in seen:
      if C.identity(r['pid'])==r['identity']:os.kill(r['pid'],signal.SIGKILL)
     assert not ownhostprocesses();save('extra-hosts-cleanup.json',seen)
    def stopproviders(label):
     rows=ownproviders();seen=[]
     for r in rows:
      ident=C.identity(r['pid']);seen.append(dict(pid=r['pid'],identity=ident,comm=r['comm']))
      if ident:os.kill(r['pid'],signal.SIGTERM)
     end=time.monotonic()+5
     while ownproviders() and time.monotonic()<end:time.sleep(.1)
     for r in seen:
      if C.identity(r['pid'])==r['identity']:os.kill(r['pid'],signal.SIGKILL)
     assert not ownproviders();save(label+'-providers-closed.json',seen)
    def windowOwner(number):
     cg=ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');cf=ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
     cg.CGWindowListCopyWindowInfo.argtypes=[ctypes.c_uint32,ctypes.c_uint32];cg.CGWindowListCopyWindowInfo.restype=ctypes.c_void_p
     cf.CFPropertyListCreateData.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_long,ctypes.c_ulong,ctypes.c_void_p];cf.CFPropertyListCreateData.restype=ctypes.c_void_p
     cf.CFDataGetLength.argtypes=[ctypes.c_void_p];cf.CFDataGetLength.restype=ctypes.c_long;cf.CFDataGetBytePtr.argtypes=[ctypes.c_void_p];cf.CFDataGetBytePtr.restype=ctypes.c_void_p;cf.CFRelease.argtypes=[ctypes.c_void_p]
     rows=cg.CGWindowListCopyWindowInfo(8,number);assert rows;data=cf.CFPropertyListCreateData(None,rows,100,0,None);assert data
     try:values=plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data),cf.CFDataGetLength(data)))
     finally:cf.CFRelease(data);cf.CFRelease(rows)
     exact=[r for r in values if r['kCGWindowNumber']==number];assert len(exact)==1;return exact[0]
    def frame(host,label):
     status=host.status();owner=windowOwner(host.window);assert owner['kCGWindowOwnerPID']==host.p.pid and owner['kCGWindowLayer']==0 and owner['kCGWindowIsOnscreen'] is True
     path=OUT/(label+'.png');command(['/usr/sbin/screencapture','-l'+str(host.window),'-o','-x',str(path)],label+'-capture',10)
     raw=command([str(RUNTIME/'recognize'),str(path)],label+'-ocr',20);ocr=json.loads(raw)
     colors=PIX.colors(path);text=' '.join(x['text'] for x in ocr['observations'])
     row=dict(file=path.name,sha256=C.SHA(path),status=status,windowOwner=owner,ocr=ocr,colors=colors,text=text);captures.append(row);return row
    def accepted(row,word):
     return accepted_frame(row,word)
    registration=PrivateRegistration(command,APP,EXT)
    try:
     verify();assert not RUNTIME.exists() and not C.own()
     cg=ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');cg.CGPreflightScreenCaptureAccess.restype=ctypes.c_bool
     assert cg.CGPreflightScreenCaptureAccess(),'Existing screen capture permission unavailable; no prompt requested'
     admission=[]
     for _ in range(25):admission.append(G.unlocked());save('admission.json',admission);assert admission[-1];time.sleep(.2)
     power=subprocess.Popen(['/usr/bin/caffeinate','-d','-i','-t','900'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=False);remember(power)
     assert ID not in command(['pluginkit','-m','-Avv','-i',ID],'provider-before').decode(),'unknownexistingprivateprovider'
     before=handler('handler-before');save('ordinary-handler.json',dict(before=before))
     stage_runtime(original,recognize,Path(P['fixtures']),RUNTIME);verify()
     command(['codesign','--verify','--deep','--strict',str(APP)],'staged-signature')
     registration.open()
     command(['pluginkit','-m','-Avv','-i',ID],'registered-provider')
     lf=(OUT/'system.ndjson').open('x');le=(OUT/'system.stderr').open('x');log=subprocess.Popen(['/usr/bin/log','stream','--style','ndjson','--level','info','--predicate','subsystem == "design.highgain.margined.benchmark.ql14"'],stdin=subprocess.DEVNULL,stdout=lf,stderr=le,start_new_session=False);remember(log)
     spec=importlib.util.spec_from_file_location('pixels',P['pixels']);PIX=importlib.util.module_from_spec(spec);spec.loader.exec_module(PIX)
     qual=Host('qualification');blank=frame(qual,'negative-blank');assert not accepted(blank,'ALPHA') and blank['colors']['green']<1000 and blank['colors']['blue']<1000
     rawfile=RUNTIME/'fixtures/docs/negative-raw-source.txt';token=qual.send('open',rawfile);qual.response('requested',token)
     until=time.monotonic()+3
     while time.monotonic()<until:check();time.sleep(.1)
     raw=frame(qual,'negative-raw');assert not accepted(raw,'NEGATIVE') and not providerEvents(rawfile.name) and raw['colors']['green']<1000 and raw['colors']['blue']<1000
     assert 'margined:thread' in raw['text'] or 'messages:' in raw['text'] or '# Preview NEGATIVE' in raw['text'],raw['text']
     doc=RUNTIME/'fixtures/docs/functional.marginedqlbench14';token=qual.send('open',doc);qual.response('requested',token);end=time.monotonic()+40;functional=None;functionalFrames=[];seen=set();required={'Alex','Sam','ALMOND','WALNUT','Discussions'}
     for attempt in range(12):
      check();assert time.monotonic()<end
      row=frame(qual,'functional-'+str(attempt));text=row['text']
      stages={x['stage'] for x in providerEvents(doc.name)}
      rawSource=any(w in text for w in ['margined:thread','messages:','author:','# Preview NEGATIVE'])
      native=any(o['text'] in ['Discussions','Alex','Sam','Appendix ALMOND is readable.','Reply WALNUT remains portable.'] for o in row['ocr']['observations'])
      if not rawSource and native and stages=={'request','ready','deliver'}:
       functionalFrames.append(row);seen.update(w for w in required if w in text)
       if required<=seen:functional=row;break
      if attempt in [3,6,9]:qual.response('page-down-requested',qual.send('page-down'))
      time.sleep(.25)
     assert functional,'Actualsystemdiscussionappendixnotproven';save('qualification.json',dict(accepted=True,blank=blank,raw=raw,appendix=functional,appendixFrames=functionalFrames,visibleFields=sorted(seen),providerEvents=providerEvents(doc.name)))
     qual.close();assert qual.closedCleanly,'Normal qualified host shutdown required';stopproviders('qualification')
     words=P['words']
     for mode in [args.kind]:
      host=None;providerPID=None
      if mode=='warm':
       host=Host('primed-warm')
       baseline=RUNTIME/'fixtures/docs/unmeasured-baseline.marginedqlbench14'
       token=host.send('open',baseline);baselineRequest=host.response('requested',token);primed=None;primeEnd=time.monotonic()+40
       for attempt in range(15):
        check();assert time.monotonic()<primeEnd
        row=frame(host,f'unmeasured-baseline-{attempt:02}');events=providerEvents(baseline.name)
        if accepted(row,'BASELINE') and {e['stage'] for e in events}=={'request','ready','deliver'}:
         pids={e['pid'] for e in events};assert len(pids)==1;providerPID=pids.pop();assert any(r['pid']==providerPID for r in ownproviders());primed=row;break
        time.sleep(.2)
       assert primed,'A real rendered baseline must warm the provider before measurements'
       save('warmup.json',dict(measured=False,request=baselineRequest,frame=primed,events=events,hostPID=host.p.pid,providerPID=providerPID,providerIdentity=C.identity(providerPID)))
      for i,word in enumerate(words):
       check();verify()
       if mode=='cold' or host is None:host=Host(mode+'-'+str(i))
       path=RUNTIME/'fixtures/docs'/f'{mode}-{i:02}.marginedqlbench14';token=host.send('open',path);request=host.response('requested',token);end=time.monotonic()+(40 if mode=='cold' else 20);chosen=None
       for attempt in range(15):
        check();assert time.monotonic()<end
        row=frame(host,f'{mode}-{i:02}-frame-{attempt:02}');events=providerEvents(path.name);stages={x['stage'] for x in events}
        if accepted(row,word) and stages=={'request','ready','deliver'}:
         pids={x['pid'] for x in events};assert len(pids)==1;pid=pids.pop();assert any(r['pid']==pid for r in ownproviders())
         if mode=='warm' and providerPID is not None:assert pid==providerPID,'warmproviderrestarted'
         providerPID=pid;chosen=row;break
        time.sleep(.2)
       assert chosen,(mode,i,'noactualsystemframe')
       # Host and provider use the same monotonic uptime clock. Endpoint includes capture/OCR overhead.
       class Timebase(ctypes.Structure):_fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
       lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib');lib.mach_absolute_time.restype=ctypes.c_uint64;lib.mach_timebase_info.argtypes=[ctypes.POINTER(Timebase)];tb=Timebase();assert lib.mach_timebase_info(ctypes.byref(tb))==0 and tb.denom
       observed=int(lib.mach_absolute_time())*tb.numer//tb.denom;assert observed>=request['request_ns']
       sample=dict(mode=mode,index=i,word=word,file=path.name,hostPID=host.p.pid,providerPID=providerPID,providerIdentity=C.identity(providerPID),providerExecutable=str(EXT.resolve()/'Contents/MacOS/MarginedQuickLook'),request_ns=request['request_ns'],observed_ns=observed,milliseconds=(observed-request['request_ns'])/1e6,frame=chosen,events=events)
       assert all(request['request_ns']<=x['uptime_ns']<=observed for x in events)
       samples.append(sample);save('samples.json',samples);print('ACCEPT',mode,i,round(sample['milliseconds']),flush=True)
       if mode=='cold':host.close();assert host.closedCleanly;host=None;stopproviders(f'cold-{i:02}')
      if host:host.close();assert host.closedCleanly;stopproviders('warm-final')
     verify()
    except BaseException as e:fail=repr(e);raise
    finally:
     for host in hosts:
      try:host.close()
      except BaseException as e:fail=fail or repr(e)
     try:stopExtraHosts()
     except BaseException as e:fail=fail or repr(e)
     try:stopproviders('final')
     except BaseException as e:fail=fail or repr(e)
     if log is not None and log.poll() is None:log.terminate()
     try:registration.close()
     except BaseException as e:fail=fail or repr(e)
     try:
      after=handler('handler-after',cleanup=True);save('ordinary-handler.json',dict(before=before,after=after,unchanged=before==after));assert before==after
     except BaseException as e:fail=fail or repr(e)
     for p,ident in owned:
      if p.poll() is None:p.terminate()
      try:p.wait(timeout=5)
      except subprocess.TimeoutExpired:p.kill();p.wait()
     try:
      assert not ownproviders() and not ownhostprocesses()
      if RUNTIME.exists():shutil.rmtree(RUNTIME)
     except BaseException as e:fail=fail or repr(e)
     save('commands.json',commands);save('captures.json',captures);save('process-census.json',census);save('terminal.json',dict(failure=fail,seconds=time.monotonic()-start,samples=len(samples),guardObservations=G.observations,owned=[dict(pid=p.pid,identity=ident,returncode=p.returncode) for p,ident in owned],hosts=[dict(pid=h.p.pid,identity=h.ident,returncode=h.p.returncode,closedCleanly=h.closedCleanly) for h in hosts],providers=ownproviders(),remainingHostProcesses=ownhostprocesses()))
     try:summary=summarize(samples,args.kind,args.samples) if fail is None else None
     except BaseException as e:fail=repr(e);summary=None
     report=dict(schema=1,status='ok' if fail is None else 'error',error=fail,kind=args.kind,summary=summary,source=source,hostFiles=bundle,recognizeSHA256=recognizeSHA,fixtureFiles=M.file_map(fixtures),boundary='system-private-uti-pixels-with-verification-overhead',finderDefaultAssociationMeasured=False,hostConstructionIncluded=False,unmeasuredWarmup=args.kind=='warm',samples=samples)
     save('report.json',report)
    if fail:raise RuntimeError(fail)
    print(json.dumps(dict(status='ok',summary=summary)),flush=True)



def interrupt_on_termination(_signal,_frame):
    raise KeyboardInterrupt('Benchmark termination requested')


def main():
    signal.signal(signal.SIGTERM,interrupt_on_termination)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',type=Path,required=True,help='Dedicated signed private ScopeHost.app; never Margined.app')
    parser.add_argument('--recognize',type=Path,required=True,help='Compiled saved-image Vision helper')
    parser.add_argument('--output',type=Path,required=True,help='New report directory; never overwritten')
    parser.add_argument('--kind',choices=['cold','warm'],required=True)
    parser.add_argument('--samples',type=int,choices=range(1,21),default=20,metavar='1..20')
    execute(parser.parse_args())

if __name__=='__main__':main()
