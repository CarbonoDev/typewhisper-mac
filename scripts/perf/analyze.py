import re,sys,collections
f=open(sys.argv[1]).read().split('\n')
thr=int(sys.argv[3]) if len(sys.argv)>3 else 0
starts=[i for i,l in enumerate(f) if re.match(r'^    \d+ Thread_',l)]
start=starts[thr]
end=starts[thr+1] if thr+1<len(starts) else len(f)
lines=f[start+1:end]
total=int(re.search(r'^\s+(\d+) Thread',f[start]).group(1))
pat=re.compile(r'^([\s\+\!\:\|]*)(\d+) (.*?)\s+\(in ([^)]+)\)')
parsed=[]
for l in lines:
    m=pat.match(l)
    if not m: continue
    sym=re.sub(r'\s+\+ \d+\s*$','',m.group(3).strip())
    parsed.append((len(m.group(1)),int(m.group(2)),sym,m.group(4)))
incl=collections.Counter(); self_=collections.Counter(); st=[]
for d,c,s,lib in parsed:
    while st and st[-1][0]>=d:
        st.pop()
    key=(s,lib)
    if st: self_[st[-1][1]]-=c
    if key not in [x[1] for x in st]: incl[key]+=c
    self_[key]+=c
    st.append((d,key))
idle=sum(v for (s,l),v in self_.items() if 'mach_msg' in s)
print(f[start].strip()[:80]); print("total",total,"idle(mach_msg self)",idle,"busy",total-idle)
print("--- app inclusive")
for (s,l),v in incl.most_common():
    if 'TypeWhisper' in l and v>=int(sys.argv[2]): print(v, s[:220])
print("--- top self")
for (s,l),v in self_.most_common(35): print(v,l,s[:140])
