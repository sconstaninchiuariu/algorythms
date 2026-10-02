import sys,re
def load(fn,settle):
    ev=[]
    for l in open(fn):
        if not l.startswith('EVT|'): continue
        p=l.strip().split('|')
        ty=p[1]
        if ty not in('ARM','MSS','ENTRY','CHANCE','LIQ','EXIT'): continue
        # time field
        tm=[x for x in p if re.match(r'\d{4}\.\d\d\.\d\d \d\d:\d\d',x)]
        if not tm: continue
        t=tm[0]
        ev.append((ty,t,p))
    return ev
def norm(e):
    ty,t,p=e
    if ty=='ENTRY': return (ty,t,p[3],p[4],p[5],p[6])      # side close sl tp
    if ty=='EXIT': return (ty,t,p[3].split('=')[1][0]=='-')
    if ty=='LIQ': return (ty,t,p[3].split()[0:8].__str__())
    return (ty,t)+tuple(p[3:])
cpp=load('out1.txt',0); ref=load('ref1.txt',0)
first=cpp[0][1]
from datetime import datetime,timedelta
def pt(s): return datetime.strptime(s,'%Y.%m.%d %H:%M')
settle=pt(first)+timedelta(days=int(sys.argv[1]) if len(sys.argv)>1 else 10)
c=[norm(e) for e in cpp if pt(e[1])>=settle]
r=[norm(e) for e in ref if pt(e[1])>=settle]
print(len(c),len(r))
for i,(a,b) in enumerate(zip(c,r)):
    if a!=b:
        print('first divergence at',i); 
        for k in range(max(0,i-2),i+3): print('CPP',c[k] if k<len(c) else None); 
        for k in range(max(0,i-2),i+3): print('REF',r[k] if k<len(r) else None)
        break
else: print('identical prefix; lens',len(c),len(r))
