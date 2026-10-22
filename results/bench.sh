#!/usr/bin/env zsh
# FULL DISCLOSURE: THIS SCRIPT WAS NOT WRITTEN BY MYSELF.
set -euo pipefail
zmodload zsh/datetime

readonly SCRIPT_DIR="${0:A:h}"
readonly DURATION=180
readonly STEADY_FROM=120
RUNS="${RUNS:-3}"
GPU="${GPU:-0}"
WARMUP="${WARMUP:-5}"
COOLDOWN="${COOLDOWN:-15}"
VIDEO_PATH="$HOME/Videos/testing.mp4"

typeset -a cmd TOOLS
TOOLS=("$@")
(( ${#TOOLS} )) || TOOLS=(baseline gsr vice obs wayclip)

set_cmd() {
    case "$1" in
        gsr)      cmd=(gpu-screen-recorder -w screen -s 2560x1440 -f 60 -k h264 -bm cbr -q 15000 -ac opus -a "default_output|default_input" -r 120 -c mkv -o /tmp) ;;
        wayclip)  cmd=(/home/kony/Documents/GitHub/daemon/target/release/wayclip-daemon) ;;
        obs)      cmd=(obs --startreplaybuffer --minimize-to-tray) ;;
        vice)     cmd=(vice start --no-open-ui) ;;
        baseline) cmd=(sleep 100000) ;;
        *) echo "[-] Unknown tool: $1 (valid: gsr wayclip obs vice baseline)" >&2; exit 1 ;;
    esac
}

for t in "${TOOLS[@]}"; do set_cmd "$t"; done
[ -f "$VIDEO_PATH" ] || { echo "[-] Video not found: $VIDEO_PATH"; exit 1; }
command -v nvidia-smi >/dev/null || { echo "[-] nvidia-smi not found"; exit 1; }

OUT="$SCRIPT_DIR/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/raw"
{
    echo "date: $(date -Is)"
    echo "gpu: $(nvidia-smi -i "$GPU" --query-gpu=name,driver_version --format=csv,noheader)"
    echo "runs: $RUNS, duration: ${DURATION}s, steady state from ${STEADY_FROM}s, warmup ${WARMUP}s, cooldown ${COOLDOWN}s"
    echo "workload: mpv --fullscreen --loop=inf --hwdec=auto $VIDEO_PATH"
    for t in "${TOOLS[@]}"; do set_cmd "$t"; echo "$t: ${cmd[*]}"; done
} > "$OUT/meta.txt"
echo "tool,run,cpu_avg,ram_avg_mb,ram_max_mb,vram_delta_mb,vram_proc_mb,gpu_delta_pct,nvenc_pct,nvenc_proc_pct,sm_proc_pct" > "$OUT/runs.csv"

TMP=""
TARGET_PID=""
MPV_PID=""
PMON_PID=""

num() { local v="${1//[^0-9]/}"; echo "${v:-0}"; }

ptree() { local c; echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null || true); do ptree "$c"; done; }

gpu_query() {
    nvidia-smi -i "$GPU" --query-gpu=memory.used,utilization.gpu,utilization.encoder \
        --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' || true
}

ticks() {
    local p v t=0
    for p in $(ptree "$TARGET_PID"); do
        v=$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $12+$13}' || true)
        t=$(( t + ${v:-0} ))
    done
    echo "$t"
}

stop_procs() {
    local p k alive
    local -a pids
    pids=()
    if [ -n "$PMON_PID" ]; then kill -TERM "$PMON_PID" 2>/dev/null || true; fi
    if [ -n "$TARGET_PID" ]; then pids+=($(ptree "$TARGET_PID")); fi
    if [ -n "$MPV_PID" ]; then pids+=("$MPV_PID"); fi
    for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
    for k in {1..100}; do   # up to ~10s for a graceful exit (OBS is slow)
        alive=0
        for p in $pids; do if kill -0 "$p" 2>/dev/null; then alive=1; fi; done
        [ "$alive" -eq 0 ] && break
        sleep 0.1
    done
    for p in $pids; do kill -9 "$p" 2>/dev/null || true; done
    PMON_PID=""; TARGET_PID=""; MPV_PID=""
    return 0
}
drop_tmp() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; TMP=""; }

trap 'trap "" INT TERM; stop_procs; drop_tmp' EXIT
trap 'echo; echo "[*] Interrupted, cleaning up..."; exit 130' INT TERM

run_once() {
    local tool="$1" r="$2"
    local -a cmd
    local sv=0 sg=0 se=0 j V G E D i
    local BASE_VRAM BASE_GPU BASE_ENC CLK START_TS PREV_TS PREV_T NOW_TS NOW_T CPU ELAPSED RAM plist N LOST=0
    local raw="$OUT/raw/${tool}_run${r}.csv"
    set_cmd "$tool"
    TMP=$(mktemp -d)
    echo "=== $tool, run $r/$RUNS ==="

    mpv --fullscreen --loop=inf --hwdec=auto "$VIDEO_PATH" >/dev/null 2>&1 &
    MPV_PID=$!
    sleep 3

    for j in 1 2 3 4 5; do
        IFS=, read -r V G E <<< "$(gpu_query)"
        sv=$(( sv + $(num "${V:-}") ))
        sg=$(( sg + $(num "${G:-}") ))
        se=$(( se + $(num "${E:-}") ))
        sleep 0.5
    done
    BASE_VRAM=$(( sv / 5 )); BASE_GPU=$(( sg / 5 )); BASE_ENC=$(( se / 5 ))
    echo "[*] Baseline (mpv only): VRAM ${BASE_VRAM} MB, GPU ${BASE_GPU}%, NVENC ${BASE_ENC}%"

    echo "[*] Launching: ${cmd[*]}"
    "${cmd[@]}" > "$OUT/raw/${tool}_run${r}.log" 2>&1 &
    TARGET_PID=$!
    sleep "$WARMUP"
    if ! kill -0 "$TARGET_PID" 2>/dev/null; then
        echo "[-] Recorder died during warmup (see raw/${tool}_run${r}.log)."
        stop_procs; drop_tmp
        return 1
    fi

    CLK=$(getconf CLK_TCK)
    START_TS=$EPOCHREALTIME
    PREV_TS=$START_TS
    PREV_T=$(ticks)

    nvidia-smi pmon -i "$GPU" -s um -o T -d 1 -c "$DURATION" > "$TMP/pmon.txt" 2>/dev/null &
    PMON_PID=$!

    echo "[*] Profiling for ${DURATION}s (recording only, no save)..."
    for ((i=1; i<=DURATION; i++)); do
        sleep 1
        if ! kill -0 "$TARGET_PID" 2>/dev/null; then
            echo "[-] Target process lost at ${i}s."
            LOST=1
            break
        fi

        NOW_TS=$EPOCHREALTIME
        NOW_T=$(ticks)
        CPU=$(awk -v a="$NOW_T" -v b="$PREV_T" -v c="$NOW_TS" -v d="$PREV_TS" -v h="$CLK" \
            'BEGIN { x=(a-b)/h/(c-d)*100; if (x<0) x=0; printf "%.1f", x }')
        ELAPSED=$(awk -v a="$NOW_TS" -v b="$START_TS" 'BEGIN { printf "%.1f", a-b }')
        PREV_T=$NOW_T
        PREV_TS=$NOW_TS

        plist=$(ptree "$TARGET_PID" | paste -sd, -)
        RAM=$(ps -o rss= -p "$plist" 2>/dev/null | awk '{s+=$1} END {printf "%.2f", s/1024}' || true)
        RAM=${RAM:-0}

        echo "$(ptree "$TARGET_PID" | tr '\n' ' ')" >> "$TMP/pids.txt"

        IFS=, read -r V G E <<< "$(gpu_query)"
        V=$(num "${V:-}"); G=$(num "${G:-}"); E=$(num "${E:-}")
        D=$(( V - BASE_VRAM )); [ "$D" -lt 0 ] && D=0 || true

        echo "$ELAPSED,$CPU,$RAM,$V,$D,$G,$E" >> "$TMP/main.csv"
    done

    if [ "$LOST" -eq 1 ]; then kill -TERM "$PMON_PID" 2>/dev/null || true; fi
    wait "$PMON_PID" 2>/dev/null || true
    PMON_PID=""
    stop_procs

    touch "$TMP/pids.txt" "$TMP/pmon.txt" "$TMP/main.csv"
    awk -v pids="$(tr ' ' '\n' < "$TMP/pids.txt" | sort -u | tr '\n' ' ')" '
    function emit() { printf "%d,%d,%d\n", fb, sm, enc }
    function val(name,   idx) {
        if (!col[name]) return 0
        idx = col[name] + off
        return ($idx ~ /^[0-9]+$/) ? $idx : 0
    }
    BEGIN { n = split(pids, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    /^#/ {
        line = $0; sub(/^#/, "", line)
        nh = split(line, h, " ")
        ok = 0
        for (i = 1; i <= nh; i++) if (h[i] == "pid") ok = 1
        if (ok) {
            delete col
            for (i = 1; i <= nh; i++) col[h[i]] = i
            hasT = (tolower(h[1]) ~ /time/)
        }
        next
    }
    NF == 0 { next }
    {
        off = (($1 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) && !hasT) ? 1 : 0
        if ($1 != cur) { if (cur != "") emit(); cur = $1; fb = 0; sm = 0; enc = 0 }
        if (!col["pid"]) next
        pid = $(col["pid"] + off)
        if (pid in want) { fb += val("fb"); sm += val("sm"); enc += val("enc") }
    }
    END { if (cur != "") emit() }
    ' "$TMP/pmon.txt" > "$TMP/pmon_agg.csv" || true

    N=$(wc -l < "$TMP/main.csv" | tr -d ' ')
    head -n "$N" "$TMP/pmon_agg.csv" > "$TMP/pmon_cut.csv"
    {
        echo "Timestamp_s,CPU_Percent,RAM_RSS_MB,Total_VRAM_MB,VRAM_Delta_MB,GPU_Util_Percent,NVENC_Util_Percent,Proc_VRAM_MB,Proc_SM_Percent,Proc_NVENC_Percent"
        paste -d, "$TMP/main.csv" "$TMP/pmon_cut.csv"
    } > "$raw"
    drop_tmp

    if [ "$LOST" -eq 1 ]; then return 1; fi

    awk -F',' -v tool="$tool" -v run="$r" -v st="$STEADY_FROM" -v bg="$BASE_GPU" '
    NR == 1 { next }
    $1 + 0 >= st {
        n++; cpu += $2; ram += $3; if ($3 + 0 > rmax) rmax = $3 + 0
        vd += $5; if ($8 + 0 > pv) pv = $8 + 0
        g += $6; e += $7; sm += $9; pe += $10
    }
    END {
        if (n == 0) exit 1
        gd = g / n - bg; if (gd < 0) gd = 0
        printf "%s,%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f\n", tool, run, cpu/n, ram/n, rmax, vd/n, pv, gd, e/n, pe/n, sm/n
    }' "$raw" >> "$OUT/runs.csv" || { echo "[-] No steady-state samples."; return 1; }
    echo "[+] $(tail -n1 "$OUT/runs.csv")"
}

echo "[*] ${RUNS} runs x ${#TOOLS} tools (${TOOLS[*]}), ~$(( RUNS * ${#TOOLS} * (DURATION + WARMUP + COOLDOWN + 8) / 60 )) min. Output: $OUT"

for ((r=1; r<=RUNS; r++)); do
    for tool in "${TOOLS[@]}"; do
        run_once "$tool" "$r" || echo "[-] $tool run $r failed, skipping"
        sleep "$COOLDOWN"
    done
done

echo
awk -F',' '
function median(arr, n,   i, j, t, a) {
    for (i = 1; i <= n; i++) a[i] = arr[i]
    for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j+1] = a[j]; a[j+1] = t }
    return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
}
NR == 1 { next }
{
    t = $1
    if (!(t in seen)) { seen[t] = 1; order[++nt] = t }
    k = ++cnt[t]
    for (c = 3; c <= 11; c++) val[t, c, k] = $c + 0
}
END {
    print "| Tool | Runs | CPU % (median) | CPU min-max | RAM avg MB | RAM peak MB | VRAM delta MB | VRAM proc MB | GPU delta % | NVENC % |"
    print "|---|---|---|---|---|---|---|---|---|---|"
    for (ti = 1; ti <= nt; ti++) {
        t = order[ti]; n = cnt[t]
        for (c = 3; c <= 11; c++) {
            for (k = 1; k <= n; k++) tmp[k] = val[t, c, k]
            med[c] = median(tmp, n)
            if (c == 3) { mn = 1e9; mx = -1; for (k = 1; k <= n; k++) { if (tmp[k] < mn) mn = tmp[k]; if (tmp[k] > mx) mx = tmp[k] } }
        }
        printf "| %s | %d | %.1f | %.1f-%.1f | %.0f | %.0f | %.0f | %.0f | %.1f | %.1f |\n", t, n, med[3], mn, mx, med[4], med[5], med[6], med[7], med[8], med[9]
    }
}' "$OUT/runs.csv" | tee "$OUT/table.md"
echo
echo "Results in: $OUT  (table.md, runs.csv, meta.txt, raw/)"
