#!/bin/sh
set -eu
BIN=${BIN:-./ninit-test}
[ -x "$BIN" ] || { echo "FAIL: binary missing"; exit 1; }
THRESHOLD=${THRESHOLD:-0}
echo "I2: spawning 500 short-lived children"
i=0
while [ $i -lt 500 ]; do
  ( exit 0 ) &
  i=$((i+1))
done
wait
# sample at t+100ms
sleep 0.1
zombies=0
for p in /proc/[0-9]*; do
  st=$(awk '{print $3}' "$p/stat" 2>/dev/null || true)
  [ "$st" = "Z" ] && zombies=$((zombies+1))
done
echo "zombies_at_100ms=$zombies"
# time to reach 0
t=0
while [ $t -lt 50 ]; do
  z=0
  for p in /proc/[0-9]*; do
    st=$(awk '{print $3}' "$p/stat" 2>/dev/null || true)
    [ "$st" = "Z" ] && z=$((z+1))
  done
  if [ "$z" -eq 0 ]; then
    echo "time_to_zero_ms=$(( (t+1)*100 ))"
    break
  fi
  sleep 0.1
  t=$((t+1))
done
if [ "$zombies" -le "$THRESHOLD" ]; then
  echo "I2 PASS: zombies_at_100ms=$zombies threshold=$THRESHOLD"
  exit 0
else
  echo "I2 FAIL: zombies_at_100ms=$zombies threshold=$THRESHOLD"
  exit 1
fi