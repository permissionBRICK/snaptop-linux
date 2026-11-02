# Re-enable (=m) every option Debian's arm64 config builds as a module that our config lacks.
import re, subprocess
import sys
# Usage: restore-all-debian-modules.py <debian arm64 config> [kernel tree]
deb=sys.argv[1]
tree=sys.argv[2] if len(sys.argv)>2 else 'linux'
debm={l.split('=')[0][7:] for l in open(deb) if l.startswith('CONFIG_') and l.strip().endswith('=m')}
cur={}
for l in open(tree+'/.config'):
    m=re.match(r'CONFIG_(\w+)=(.*)',l)
    if m: cur[m.group(1)]=m.group(2)
todo=sorted(s for s in debm if cur.get(s) not in ('m','y'))
args=[]
for s in todo: args+=['-m',s]
for i in range(0,len(args),400): subprocess.run([tree+'/scripts/config','--file',tree+'/.config']+args[i:i+400],check=True)
print(len(todo),'Debian module options re-enabled')
