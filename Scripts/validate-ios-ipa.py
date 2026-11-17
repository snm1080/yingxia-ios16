import pathlib, subprocess, plistlib, json, re, importlib.metadata as metadata, hashlib, sys
repo=pathlib.Path.cwd(); out=pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True); app=pathlib.Path(sys.argv[1]); source=repo/'build/ApplePython/iphoneos'
def command(*args):return subprocess.check_output(args,text=True)
def version(s):return tuple(map(int,s.split('.')))+(0,)*(3-len(s.split('.')))
required=dict(re.findall(r'^([A-Za-z][\w-]*)==([^\s]+)',(repo/'Runtime/PythonHost/requirements.txt').read_text(),re.M))
installed={d.metadata['Name'].lower().replace('_','-'):d.version for d in metadata.distributions(path=[str(app/'PythonHost/site-packages')])}
missing={n:v for n,v in required.items() if installed.get(n.lower().replace('_','-'))!=v}
records=[];errors=[]
for f in sorted((app/'Frameworks').glob('*.framework')):
 info=plistlib.loads((f/'Info.plist').read_bytes());binary=f/info['CFBundleExecutable'];build=command('xcrun','vtool','-show-build',str(binary));archs=command('lipo','-archs',str(binary)).strip().split()
 minos=re.findall(r'\bminos\s+(\S+)',build); platforms=re.findall(r'\bplatform\s+(\S+)',build)
 loads=command('otool','-l',str(binary));deps=[]
 for block in loads.split('Load command ')[1:]:
  match=re.search(r'\n\s+cmd (LC_(?:LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD)_DYLIB)\n',block)
  if match:
   dep=re.search(r'\n\s+name (.+?) \(offset',block).group(1);resolved=True
   if dep.startswith('@rpath/'):resolved=(app/'Frameworks'/dep[len('@rpath/'):]).is_file()
   elif dep.startswith('@loader_path/'):resolved=(binary.parent/dep[len('@loader_path/'):]).is_file()
   elif dep.startswith('@executable_path/'):resolved=(app/dep[len('@executable_path/'):]).is_file()
   elif not dep.startswith(('/usr/lib/','/System/Library/')):resolved=False
   deps.append({'kind':match.group(1),'name':dep,'resolved':resolved})
   if not resolved:errors.append(f'{f.name}: unresolved {dep}')
 if archs!=['arm64']:errors.append(f'{f.name}: archs {archs}')
 if not minos or any(version(x)>version('16.2') for x in minos):errors.append(f'{f.name}: minos {minos}')
 if platforms!=['IOS']:errors.append(f'{f.name}: platforms {platforms}')
 if version(info.get('MinimumOSVersion','999'))>version('16.2'):errors.append(f'{f.name}: plist minimum too high')
 if not (f/'PrivacyInfo.xcprivacy').exists():errors.append(f'{f.name}: no privacy manifest')
 source_binary=source/'Frameworks'/f.name/info['CFBundleExecutable']
 if source_binary.exists() and source_binary.read_bytes()!=binary.read_bytes():errors.append(f'{f.name}: embedded bytes differ')
 records.append({'framework':f.name,'archs':archs,'minos':minos,'platforms':platforms,'plist_minimum':info.get('MinimumOSVersion'),'dependencies':deps,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()})
fworks=list((app/'python').rglob('*.fwork'))+list((app/'PythonHost').rglob('*.fwork'))
for f in fworks:
 dest=app/f.read_text().strip()
 if not dest.is_file():errors.append(f'Broken framework pointer: {f.relative_to(app)}')
for name in ['_cffi_backend','cryptography.hazmat.bindings._rust']:
 if not any(r['framework']==name+'.framework' for r in records):errors.append('Missing extension framework '+name)
loose=[str(p.relative_to(app)) for root in ['python','PythonHost'] for p in (app/root).rglob('*.so')]
if loose:errors.append('Loose native extensions '+str(loose))
if missing:errors.append('Missing declared packages '+str(missing))
report={'framework_count':len(records),'python_framework_count':len(records)-1,'required_packages':required,'installed_packages':installed,'missing_packages':missing,'fwork_count':len(fworks),'loose_extensions':loose,'frameworks':records,'errors':errors}
info=plistlib.loads((app/'Info.plist').read_bytes())
executable=app/info['CFBundleExecutable']
report['app_info']={k:info.get(k) for k in ['CFBundleIdentifier','CFBundleExecutable','CFBundleShortVersionString','CFBundleVersion','MinimumOSVersion','UIDeviceFamily']}
app_build=command('xcrun','vtool','-show-build',str(executable))
report['app_build']=app_build
report['app_archs']=command('lipo','-archs',str(executable)).strip().split()
if report['app_archs']!=['arm64']:errors.append('App architecture mismatch')
if info.get('MinimumOSVersion')!='16.2':errors.append('App plist minimum not16.2')
if re.findall(r'\bminos\s+(\S+)',app_build)!=['16.2']:errors.append('App Mach-O minimum not16.2')
if info.get('UIDeviceFamily')!=[1,2]:errors.append('Not iPhone+iPad')
report['opens_documents_in_place']=info.get('LSSupportsOpeningDocumentsInPlace') is True
if not report['opens_documents_in_place']:errors.append('Document picker in-place import support missing')
forbidden=[str(p.relative_to(app)) for p in app.rglob('*') if p.is_file() and (p.suffix.lower() in ['.jar','.jmod','.dex'] or p.name in ['libjvm.dylib','libjli.dylib'])]
report['forbidden_java_payload']=forbidden
if forbidden:errors.append('Java payload present')
symbols=command('nm','-g',str(executable))
java_symbols=[l for l in symbols.splitlines() if re.search(r'\b_?(JNI_CreateJavaVM|JNI_GetCreatedJavaVMs|TVAppleRuntime[A-Za-z_]*|dx_context_new|TVJar[A-Za-z_]*)\b',l)]
report['java_native_symbols']=java_symbols
if java_symbols:errors.append('Java native bridge linked')
# Inspect every Mach-O, including loose Swift support dylibs, not just framework bundles.
all_native=[]
for binary in app.rglob('*'):
 if not binary.is_file() or binary.is_symlink():continue
 with binary.open('rb') as f:magic=f.read(4)
 if magic not in [bytes.fromhex(h) for h in ['cffaedfe','feedfacf','cefaedfe','feedface','cafebabe','bebafeca']]:continue
 native_build=command('xcrun','vtool','-show-build',str(binary))
 native_archs=command('lipo','-archs',str(binary)).strip().split()
 native_min=re.findall(r'\bminos\s+(\S+)',native_build)
 if native_archs!=['arm64']:errors.append(str(binary.relative_to(app))+': architecture '+str(native_archs))
 if not native_min or any(version(v)>version('16.2') for v in native_min):errors.append(str(binary.relative_to(app))+': minimum '+str(native_min))
 native_deps=[]
 for block in command('otool','-l',str(binary)).split('Load command ')[1:]:
  if not re.search(r'\n\s+cmd LC_(?:LOAD|LOAD_WEAK|REEXPORT|LOAD_UPWARD)_DYLIB\n',block):continue
  dep=re.search(r'\n\s+name (.+?) \(offset',block).group(1)
  resolved=dep.startswith(('/usr/lib/','/System/Library/'))
  for prefix,base in [('@rpath/',app/'Frameworks'),('@loader_path/',binary.parent),('@executable_path/',app)]:
   if dep.startswith(prefix):resolved=(base/dep[len(prefix):]).is_file()
  native_deps.append({'name':dep,'resolved':resolved})
  if not resolved:errors.append(str(binary.relative_to(app))+': unresolved '+dep)
 all_native.append({'path':str(binary.relative_to(app)),'archs':native_archs,'minos':native_min,'dependencies':native_deps})
report['all_native']=all_native
report['all_native_count']=len(all_native)
report['app_sha256']=hashlib.sha256(executable.read_bytes()).hexdigest()
report['errors']=errors
(out/'ipa-validation.json').write_text(json.dumps(report,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='frameworks'},indent=2))
assert not errors, errors
