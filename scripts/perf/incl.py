import re,sys,collections
f=open(sys.argv[1]).read().split('\n'); thr=0
starts=[i for i,l in enumerate(f) if re.match(r'^    \d+ Thread_',l)]
lines=f[starts[thr]+1:starts[thr+1]]
pat=re.compile(r'^([\s\+\!\:\|]*)(\d+) (.*?)\s+\(in ([^)]+)\)')
inc=collections.Counter(); st=[]
for l in lines:
    m=pat.match(l)
    if not m: continue
    d=len(m.group(1)); c=int(m.group(2)); s=re.sub(r'\s+\+ \d+\s*$','',m.group(3).strip())[:120]; lib=m.group(4)
    while st and st[-1][0]>=d: st.pop()
    k=(s,lib)
    if k not in [x[1] for x in st]: inc[k]+=c
    st.append((d,k))
pats=sys.argv[2].split('|')
for (s,l),v in inc.most_common():
    if any(p in s for p in pats): print(v,l,s)
