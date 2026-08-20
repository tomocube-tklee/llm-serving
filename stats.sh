#!/usr/bin/env bash
# Quick stats for the local llama.cpp server.
#   ./stats.sh        한 번 출력
#   ./stats.sh -w     2초마다 갱신 (Ctrl-C 종료)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/.env"
HOST="http://100.117.22.53:8080"
AUTH="Authorization: Bearer ${LLAMA_API_KEY}"

show() {
  echo "===================== llama.cpp stats $(date '+%H:%M:%S') ====================="

  # --- GPU ---
  echo "── GPU ──────────────────────────────────────────────"
  nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
    --format=csv,noheader,nounits |
    awk -F', ' '{printf "  util %3s%%   vram %s/%s MiB   temp %s°C   power %sW\n",$1,$2,$3,$4,$5}'

  # --- health + slots ---
  echo "── 서버/슬롯 ────────────────────────────────────────"
  health=$(curl -s -m 3 -H "$AUTH" "$HOST/health" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "UNREACHABLE")
  curl -s -m 3 -H "$AUTH" "$HOST/slots" 2>/dev/null | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('  health: $health  (slots 응답 없음)'); sys.exit()
busy=sum(1 for s in d if s.get('is_processing'))
print(f'  health: $health   slots: {busy}/{len(d)} busy')
for s in d:
    if s.get('is_processing'):
        p=(s.get('prompt') or '')[:50].replace(chr(10),' ')
        print(f\"    slot {s['id']}: BUSY  n_past={s.get('n_past','?')}  {p!r}\")
" 2>/dev/null || echo "  health: $health"

  # --- recent request timings (from container logs) ---
  echo "── 최근 요청 (prefill / 생성) ───────────────────────"
  docker logs llama-server 2>&1 | grep "print_timing" | tail -60 | python3 -c "
import sys,re
tasks={}
for line in sys.stdin:
    tid=re.search(r'task (\d+)',line)
    if not tid: continue
    tid=tid.group(1)
    t=tasks.setdefault(tid,{})
    if 'prompt eval time' in line:
        m=re.search(r'=\s+([\d.]+) ms /\s+(\d+) tokens.*?([\d.]+) tokens per second',line)
        if m: t['pp']=(int(m.group(2)),float(m.group(3)))
    elif 'eval time' in line and 'prompt' not in line:
        m=re.search(r'=\s+([\d.]+) ms /\s+(\d+) tokens.*?([\d.]+) tokens per second',line)
        if m: t['tg']=(int(m.group(2)),float(m.group(3)))
rows=list(tasks.items())[-8:]
if not rows: print('  (아직 완료된 요청 없음)')
for tid,t in rows:
    pp=t.get('pp'); tg=t.get('tg')
    pps=f\"prefill {pp[0]:>5}tok @ {pp[1]:>7.0f} tok/s\" if pp else 'prefill   -'
    tgs=f\"gen {tg[0]:>5}tok @ {tg[1]:>6.1f} tok/s\" if tg else 'gen   -'
    print(f'  task {tid:>6}:  {pps}   |   {tgs}')
"
  echo "================================================================="
}

if [[ "${1:-}" == "-w" ]]; then
  while true; do clear; show; sleep 2; done
else
  show
fi
