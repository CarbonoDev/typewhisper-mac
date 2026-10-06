import re,sys,collections
f=open(sys.argv[1]).read().split('\n'); target=sys.argv[2]; thr=int(sys.argv[3]) if len(sys.argv)>3 else 0
starts=[i for i,l in enumerate(f) if re.match(r'^    \d+ Thread_',l)]
lines=f[starts[thr]+1:(starts[thr+1] if thr+1<len(starts) else len(f))]
pat=re.compile(r'^([\s\+\!\:\|]*)(\d+) (.*?)\s+\(in ([^)]+)\)')
P=[]
for l in lines:
    m=pat.match(l)
    if m: P.append((len(m.group(1)),int(m.group(2)),re.sub(r'\s+\+ \d+\s*$','',m.group(3).strip()),m.group(4)))
selfc=collections.Counter(); inclc=collections.Counter(); i=0; tot=0
while i<len(P):
    d,c,s,lib=P[i]
    if s==target:
        tot+=c; j=i+1
        while j<len(P) and P[j][0]>d: j+=1
        sub=P[i:j]; st=[]
        for dd,cc,ss,ll in sub:
            while st and st[-1][0]>=dd: st.pop()
            if st: selfc[st[-1][1]]-=cc
            k=(ss[:110],ll)
            if k not in [x[1] for x in st]: inclc[k]+=cc
            selfc[k]+=cc; st.append((dd,k))
        i=j
    else: i+=1
print("target total",tot)
print("-- inclusive"); [print(v,l,s) for (s,l),v in inclc.most_common(int(sys.argv[4]) if len(sys.argv)>4 else 30)]
print("-- self"); [print(v,l,s) for (s,l),v in selfc.most_common(15)]
