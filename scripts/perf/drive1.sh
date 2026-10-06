#!/bin/bash
# Usage: drive1.sh <out-dir> <meeting-id-1> <meeting-id-2>
# Samples the running app for 10 s while opening two meetings, then a screenshot.
S=$1; M1=$2; M2=$3
PID=${PID:-$(pgrep -x TypeWhisper | head -1)}
sample $PID 10 -file $S/nav-1.txt >/dev/null 2>&1 &
SP=$!
top -l 6 -s 2 -pid $PID -stats pid,cpu,mem,th > $S/top-1.txt &
sleep 0.5
date +%T.%N > $S/nav-1.times
open "typewhisper://meeting/$M1"; echo "open $M1 $(date +%T)" >> $S/nav-1.times
sleep 3
open "typewhisper://meeting/$M2"; echo "open $M2 $(date +%T)" >> $S/nav-1.times
sleep 3
open "typewhisper://screenshot/nav1"; echo "shot $(date +%T)" >> $S/nav-1.times
wait $SP
