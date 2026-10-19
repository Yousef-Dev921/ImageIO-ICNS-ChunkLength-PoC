#!/bin/bash
# Usage: ql_wrap.sh <seconds> <file_to_thumbnail>
SECS="$1"; FILE="$2"
mkdir -p /tmp/qlcheck && rm -f /tmp/qlcheck/_out_*
OUT=/tmp/qlcheck/_out_$$
(/usr/bin/time -l qlmanage -t -s 1024 -o /tmp/qlcheck "$FILE") > "$OUT" 2>&1 &
QLPID=$!
WAITED=0
while kill -0 $QLPID 2>/dev/null && [ $WAITED -lt $SECS ]; do
   sleep 1
   WAITED=$((WAITED+1))
done
if kill -0 $QLPID 2>/dev/null; then
   kill -9 "$QLPID" 2>/dev/null
   wait $QLPID 2>/dev/null
   echo "▲▲▲ qlmanage HUNG — killed after ${SECS}s (process never completed) ▲▲▲"
   echo "    File: $FILE"
   echo "    Last captured output (may include partial /usr/bin/time -l data):"
   cat "$OUT" 2>/dev/null | sed 's/^/    /' | tail -25
else
   wait $QLPID 2>/dev/null
   echo "  (qlmanage completed in ${WAITED}s)"
   cat "$OUT" 2>/dev/null | tail -25
fi
rm -f "$OUT"
