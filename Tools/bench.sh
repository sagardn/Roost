#!/bin/bash
#
# Roost performance baseline.
#
# Read-only: it launches the installed app and measures it. It changes no
# settings and writes nothing into the bundle.
#
#   ./Tools/bench.sh            measure the installed /Applications/Roost.app
#   APP=/path/to/Roost.app ./Tools/bench.sh
#
# Idle CPU is measured from the *delta* in cumulative CPU time, not from
# `ps %cpu` -- that column is the average since the process started, so it
# reports a decaying startup transient rather than what the app is doing now.
# Measured both ways on the same run: 8.0% vs the true 6.0%.
#
set -u
APP="${APP:-/Applications/Roost.app}"
BIN="$APP/Contents/MacOS/Roost"
WINDOWS=20   # seconds per sample window
COUNT=6      # number of windows

PID=$(pgrep -f "$BIN" | head -1)
if [ -z "${PID:-}" ]; then
  echo "Roost is not running; starting it"
  open -a "$APP"
  sleep 25
  PID=$(pgrep -f "$BIN" | head -1)
fi
[ -z "${PID:-}" ] && { echo "could not find Roost"; exit 1; }

echo "pid $PID, up $(ps -o etime= -p "$PID" | tr -d ' ')"
echo "sampling $COUNT x ${WINDOWS}s"

python3 - "$PID" "$WINDOWS" "$COUNT" <<'PY'
import subprocess, sys, time
pid, window, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

def cpu_seconds():
    out = subprocess.run(["ps","-o","time=","-p",pid],
                         capture_output=True, text=True).stdout.strip()
    parts = [float(p) for p in out.replace("-", ":").split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    return parts[-3]*3600 + parts[-2]*60 + parts[-1]

samples = []
for i in range(count):
    a, t0 = cpu_seconds(), time.time()
    time.sleep(window)
    pct = (cpu_seconds() - a) / (time.time() - t0) * 100
    samples.append(pct)
    print(f"  window {i+1}: {pct:5.2f}% CPU")
samples.sort()
rss = int(subprocess.run(["ps","-o","rss=","-p",pid],
                         capture_output=True, text=True).stdout.strip())
print(f"  --> median {samples[len(samples)//2]:.2f}%  max {samples[-1]:.2f}%  RSS {rss/1024:.1f} MB")
PY

echo
echo "profile (15s, heaviest frames):"
sample "$PID" 15 -file /tmp/roost.sample.txt >/dev/null 2>&1
grep -E "^\s+[0-9]{2,}\s" /tmp/roost.sample.txt | head -15
echo "full call graph: /tmp/roost.sample.txt"
