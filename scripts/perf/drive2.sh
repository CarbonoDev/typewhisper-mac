#!/bin/bash
# Usage: drive2.sh <out-dir> <run-label> <typewhisper://url>...
# Samples the running app for 10 s while opening each URL 2.5 s apart.
S=$1; N=$2; shift 2
PID=${PID:-$(pgrep -x TypeWhisper | head -1)}
sample $PID 10 -file $S/nav-$N.txt >/dev/null 2>&1 &
SP=$!
top -l 6 -s 2 -pid $PID -stats pid,cpu,mem,th > $S/top-$N.txt &
sleep 0.5
for u in "$@"; do open "$u"; echo "$u $(date +%T)" >> $S/nav-$N.times; sleep 2.5; done
wait $SP
