from pathlib import Path
import hashlib,json,re,subprocess,sys
app=Path(sys.argv[1]).resolve()
results=[]
def run(*args):
 p=subprocess.run(args,capture_output=True,text=True)
 results.append({'command':list(args),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 assert p.returncode==0,(args,p.stderr)
 return p.stdout
run('codesign','--verify','--deep','--strict',str(app))
run('plutil','-lint',str(app/'Contents/Info.plist'),str(app/'Contents/Resources/en.lproj/Localizable.strings'),str(app/'Contents/Resources/zh-Hans.lproj/Localizable.strings'))
macos=app/'Contents/MacOS'
for binary in sorted(macos.iterdir()):
 if not binary.is_file(): continue
 assert run('lipo','-archs',str(binary)).strip()=='arm64'
 info=run('xcrun','vtool','-show-build',str(binary))
 minos=re.findall(r'\bminos\s+([0-9.]+)',info)
 assert minos and all(tuple(map(int,v.split('.'))) <= (14,0) for v in minos),(binary,minos)
 linked=run('otool','-L',str(binary))
 for line in linked.splitlines()[1:]:
  dependency=line.strip().split(' (')[0]
  if dependency.startswith('@executable_path/'):
   assert (macos/dependency.removeprefix('@executable_path/')).is_file(),dependency
  else:
   assert dependency.startswith(('/usr/lib/','/System/Library/')),dependency
result={'app':str(app),'binarySHA256':hashlib.sha256((macos/'macMTP').read_bytes()).hexdigest(),'status':'PASS','commands':results}
Path(sys.argv[2]).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print('PACKAGE PASS: arm64; executable and all runtime dylibs minos <= 14.0; bundled dependency paths and signature valid')
