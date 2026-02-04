@ -0,0 +1,908 @@
#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.9"

# -----------------------------
# Styling
# -----------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_MAG=$'\033[35m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_MAG=""
fi

ok()   { printf "%s" "${C_GREEN}PASS${C_RESET}"; }
warn() { printf "%s" "${C_YELLOW}WARN${C_RESET}"; }
bad()  { printf "%s" "${C_RED}FAIL${C_RESET}"; }

log()  { printf "%s\n" "${C_CYAN}[ehinium]${C_RESET} $*" >&2; }
err()  { printf "%s\n" "${C_RED}[ehinium]${C_RESET} $*" >&2; }

# -----------------------------
# Defaults (quick, no presets)
# -----------------------------
SUITE="express"     # express|baseline|throughput|soak|custom
MODE=""             # client|server
HOSTS=()
HOST=""
SNI=""
BIND_ADDR="0.0.0.0"

TCP_ECHO_PORT=9090
UDP_ECHO_PORT=9091
TLS_PORT=9443
IPERF_PORT=5201

PING_COUNT=10
PING_TIMEOUT=1

TCP_CONNECT_TRIES=5
TCP_CONNECT_TIMEOUT=2

CMD_TIMEOUT=8

IPERF_TIME=5
IPERF_PARALLEL=4
IPERF_UDP_BW="15M"

SOAK_LOOPS=20
SOAK_INTERVAL=0.10
SOAK_TIMEOUT=2

OUTPUT_FORMAT="terminal"   # custom only: markdown
TSV_OUT=""                 # custom only

# -----------------------------
# Cleanup
# -----------------------------
PIDS=()
TMPFILES=()
TLS_CERT=""
TLS_KEY=""

cleanup() {
  set +e
  for p in "${PIDS[@]:-}"; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  for f in "${TMPFILES[@]:-}"; do
    rm -f "$f" 2>/dev/null || true
  done
  [[ -n "${TLS_CERT:-}" ]] && rm -f "$TLS_CERT" 2>/dev/null || true
  [[ -n "${TLS_KEY:-}"  ]] && rm -f "$TLS_KEY" 2>/dev/null || true
}
trap 'cleanup; exit 0' INT TERM
trap 'cleanup; err "Unexpected error on line $LINENO"; exit 1' ERR

have() { command -v "$1" >/dev/null 2>&1; }

translate_missing() {
  local bin="$1" hint="$2"
  printf "%s" "missing: $bin"
  [[ -n "$hint" ]] && printf "%s" " ($hint)"
}

strip_ansi() { sed -r 's/\x1B\[[0-9;]*[mK]//g'; }

# -----------------------------
# Spinner wrapper (external commands)
# -----------------------------
run_with_spinner() {
  local label="$1"; shift
  local start_ts now elapsed
  local spin='|/-\'
  local i=0
  start_ts=$(date +%s)

  local out errf
  out=$(mktemp) ; errf=$(mktemp)
  TMPFILES+=("$out" "$errf")

  set +e
  ( "$@" >"$out" 2>"$errf" ) &
  local pid=$!
  set -e

  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    elapsed=$((now - start_ts))
    printf "\r%s[%02d:%02d] %s %c%s" "${C_DIM}" $((elapsed/60)) $((elapsed%60)) "$label" "${spin:i%4:1}" "${C_RESET}" >&2
    i=$((i+1))
    sleep 1
  done

  set +e
  wait "$pid"
  local rc=$?
  set -e

  now=$(date +%s)
  elapsed=$((now - start_ts))
  printf "\r%s[%02d:%02d] %s done%s\n" "${C_DIM}" $((elapsed/60)) $((elapsed%60)) "$label" "${C_RESET}" >&2

  RUN_OUT_FILE="$out"
  RUN_ERR_FILE="$errf"
  return "$rc"
}

# -----------------------------
# Table
# -----------------------------
declare -a TESTS=()
declare -a RESULTS=()
declare -a DETAILS=()

reset_table() { TESTS=(); RESULTS=(); DETAILS=(); }
add_row() { TESTS+=("$1"); RESULTS+=("$2"); DETAILS+=("$3"); }

print_table_terminal() {
  local i n
  n=${#TESTS[@]}
  local w1=4 w2=6 w3=7
  for ((i=0;i<n;i++)); do
    local t="${TESTS[i]}"
    local r; r=$(printf "%s" "${RESULTS[i]}" | strip_ansi)
    local d="${DETAILS[i]}"
    (( ${#t} > w1 )) && w1=${#t}
    (( ${#r} > w2 )) && w2=${#r}
    (( ${#d} > w3 )) && w3=${#d}
  done

  printf "\n"
  printf "%-${w1}s | %-${w2}s | %s\n" "TEST" "RESULT" "DETAILS"
  printf "%s-+-%s-+-%s\n" "$(printf '%*s' "$w1" '' | tr ' ' '-')" "$(printf '%*s' "$w2" '' | tr ' ' '-')" "$(printf '%*s' "$w3" '' | tr ' ' '-')"
  for ((i=0;i<n;i++)); do
    printf "%-${w1}s | %-${w2}s | %s\n" "${TESTS[i]}" "${RESULTS[i]}" "${DETAILS[i]}"
  done
  printf "\n"
}

print_table_markdown() {
  local i n
  n=${#TESTS[@]}
  printf "\n| Test | Result | Details |\n|---|---|---|\n"
  for ((i=0;i<n;i++)); do
    local r; r=$(printf "%s" "${RESULTS[i]}" | strip_ansi)
    printf "| %s | %s | %s |\n" "${TESTS[i]}" "$r" "${DETAILS[i]}"
  done
  printf "\n"
}

maybe_write_tsv() {
  [[ -z "$TSV_OUT" ]] && return 0
  {
    printf "test\tresult\tdetails\n"
    local i n; n=${#TESTS[@]}
    for ((i=0;i<n;i++)); do
      local r; r=$(printf "%s" "${RESULTS[i]}" | strip_ansi)
      printf "%s\t%s\t%s\n" "${TESTS[i]}" "$r" "${DETAILS[i]}"
    done
  } > "$TSV_OUT"
  log "Wrote TSV: $TSV_OUT"
}

# -----------------------------
# Prompts
# -----------------------------
prompt_choice() {
  local title="$1"; shift
  local -a options=("$@")
  while true; do
    printf "\n%s\n" "$title"
    local i
    for ((i=0;i<${#options[@]}; i++)); do
      printf "  %d. %s\n" $((i+1)) "${options[i]}"
    done
    printf "Enter number: "
    local input
    IFS= read -r input || true
    input="${input//[[:space:]]/}"
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input>=1 && input<=${#options[@]} )); then
      CHOICE_INDEX=$((input-1))
      return 0
    fi
    err "Invalid choice. Enter a number between 1 and ${#options[@]}."
  done
}

prompt_line_nonempty() {
  local label="$1"
  while true; do
    printf "%s" "$label"
    local input
    IFS= read -r input || true
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    if [[ -n "$input" ]]; then
      PROMPT_VALUE="$input"
      return 0
    fi
    err "This value cannot be empty."
  done
}

prompt_line_default() {
  local label="$1" def="$2"
  printf "%s" "$label"
  local input
  IFS= read -r input || true
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  [[ -z "$input" ]] && PROMPT_VALUE="$def" || PROMPT_VALUE="$input"
}

pause_to_menu() {
  printf "%s" "${C_DIM}Press Enter to return to the main menu, or Ctrl+C to exit...${C_RESET}"
  IFS= read -r _ || true
}

# -----------------------------
# Validation
# -----------------------------
is_valid_host() {
  local h="$1"
  [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]]
}

parse_hosts_csv() {
  local raw="$1"
  raw="${raw// /}"
  IFS=',' read -r -a HOSTS <<< "$raw"
  local cleaned=()
  local h
  for h in "${HOSTS[@]}"; do
    [[ -z "$h" ]] && continue
    cleaned+=("$h")
  done
  HOSTS=("${cleaned[@]}")
}

# -----------------------------
# Parameters display
# -----------------------------
show_params() {
  printf "\n%s\n" "${C_DIM}Parameters:${C_RESET}"
  printf "%s\n" "${C_DIM}- host: ${HOST:-n/a}${C_RESET}"
  printf "%s\n" "${C_DIM}- sni:  ${SNI:-none}${C_RESET}"
  printf "%s\n" "${C_DIM}- ports: tcp_echo=$TCP_ECHO_PORT udp_echo=$UDP_ECHO_PORT tls=$TLS_PORT iperf3=$IPERF_PORT${C_RESET}"
  printf "%s\n" "${C_DIM}- ping:  count=$PING_COUNT timeout=${PING_TIMEOUT}s${C_RESET}"
  printf "%s\n" "${C_DIM}- tcp connect: tries=$TCP_CONNECT_TRIES timeout=${TCP_CONNECT_TIMEOUT}s${C_RESET}"
  printf "%s\n" "${C_DIM}- iperf3: time=${IPERF_TIME}s parallel=$IPERF_PARALLEL udp_bw=$IPERF_UDP_BW${C_RESET}"
  printf "%s\n" "${C_DIM}- soak: loops=$SOAK_LOOPS interval=${SOAK_INTERVAL}s timeout=${SOAK_TIMEOUT}s${C_RESET}"
}

# -----------------------------
# Server listeners
# -----------------------------
start_tcp_echo() {
  if have socat; then
    socat -T 10 TCP-LISTEN:"$TCP_ECHO_PORT",bind="$BIND_ADDR",reuseaddr,fork SYSTEM:'cat' >/dev/null 2>&1 &
    PIDS+=("$!")
    return 0
  elif have nc; then
    ( while true; do nc -l -p "$TCP_ECHO_PORT" -s "$BIND_ADDR" -q 1 -c 'cat' 2>/dev/null; done ) &
    PIDS+=("$!")
    return 0
  elif have python3; then
    python3 - <<PY >/dev/null 2>&1 &
import socket, threading
bind="${BIND_ADDR}"
port=int(${TCP_ECHO_PORT})
srv=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((bind, port))
srv.listen(50)
def h(c):
    try:
        while True:
            d=c.recv(4096)
            if not d: break
            c.sendall(d)
    except: pass
    try: c.close()
    except: pass
while True:
    c,_=srv.accept()
    threading.Thread(target=h,args=(c,),daemon=True).start()
PY
    PIDS+=("$!")
    return 0
  fi
  return 1
}

start_udp_echo() {
  if have socat; then
    socat -T 10 UDP-RECVFROM:"$UDP_ECHO_PORT",bind="$BIND_ADDR",reuseaddr,fork SYSTEM:'cat' >/dev/null 2>&1 &
    PIDS+=("$!")
    return 0
  elif have python3; then
    python3 - <<PY >/dev/null 2>&1 &
import socket
bind="${BIND_ADDR}"
port=int(${UDP_ECHO_PORT})
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((bind, port))
while True:
    data, addr = s.recvfrom(4096)
    if not data: 
        continue
    s.sendto(data, addr)
PY
    PIDS+=("$!")
    return 0
  fi
  return 1
}

start_tls_server() {
  if ! have openssl; then return 1; fi
  TLS_CERT=$(mktemp)
  TLS_KEY=$(mktemp)
  TMPFILES+=("$TLS_CERT" "$TLS_KEY")
  openssl req -x509 -newkey rsa:2048 -keyout "$TLS_KEY" -out "$TLS_CERT" -days 1 -nodes -subj "/CN=ehiniumNetProbe" >/dev/null 2>&1
  openssl s_server -quiet -accept "${BIND_ADDR}:${TLS_PORT}" -cert "$TLS_CERT" -key "$TLS_KEY" >/dev/null 2>&1 &
  PIDS+=("$!")
  return 0
}

start_iperf_server() {
  if ! have iperf3; then return 1; fi
  iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
  PIDS+=("$!")
  return 0
}

server_mode() {
  if [[ "$SUITE" == "custom" ]]; then
    prompt_line_default "Bind address [$BIND_ADDR]: " "$BIND_ADDR"
    BIND_ADDR="$PROMPT_VALUE"
  else
    BIND_ADDR="0.0.0.0"
  fi

  log "Server mode is up"
  log "Bind:     $BIND_ADDR"
  log "TCP echo: $BIND_ADDR:$TCP_ECHO_PORT"
  log "UDP echo: $BIND_ADDR:$UDP_ECHO_PORT"
  log "TLS:      $BIND_ADDR:$TLS_PORT (self-signed)"
  log "iperf3:   $BIND_ADDR:$IPERF_PORT"
  log "Press Ctrl+C to stop"

  start_tcp_echo   || err "TCP echo listener not started (need socat, nc, or python3)."
  start_udp_echo   || err "UDP echo listener not started (need socat or python3)."
  start_tls_server || err "TLS listener not started (need openssl)."
  start_iperf_server || err "iperf3 server not started (need iperf3)."

  while true; do sleep 1; done
}

# -----------------------------
# Client tests
# -----------------------------
extract_ping_loss_pct() {
  # outputs numeric loss percent (example: 0, 10, 0.5) or empty
  awk 'match($0, /([0-9.]+)%[[:space:]]+packet[[:space:]]+loss/, a){print a[1]; exit}' "$1"
}

extract_ping_rtt() {
  # rtt min/avg/max/mdev
  awk -F'=' '/rtt|round-trip/ {gsub(/ ms/,"",$2); gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$1"
}

test_icmp_ping() {
  if ! have ping; then
    add_row "icmp_ping" "$(warn)" "$(translate_missing ping "")"
    return
  fi

  run_with_spinner "icmp_ping" ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$HOST"
  local rc=$?

  local loss_pct rtt
  loss_pct=$(extract_ping_loss_pct "$RUN_OUT_FILE" || true)
  rtt=$(extract_ping_rtt "$RUN_OUT_FILE" || true)
  [[ -z "$loss_pct" ]] && loss_pct="n/a"
  [[ -z "$rtt" ]] && rtt="n/a"

  # ping exit code is 0 if at least one response received, 1 if none
  if [[ "$loss_pct" =~ ^[0-9.]+$ ]]; then
    awk -v p="$loss_pct" 'BEGIN{exit !(p==0)}' && { add_row "icmp_ping" "$(ok)" "loss ${loss_pct}%, rtt ${rtt} ms"; return; }
    awk -v p="$loss_pct" 'BEGIN{exit !(p<=20)}' && { add_row "icmp_ping" "$(warn)" "loss ${loss_pct}%, rtt ${rtt} ms"; return; }
    add_row "icmp_ping" "$(bad)" "loss ${loss_pct}%, rtt ${rtt} ms"
  else
    # if parsing failed, fall back to rc
    if [[ "$rc" -eq 0 ]]; then
      add_row "icmp_ping" "$(warn)" "loss n/a, rtt ${rtt} ms"
    else
      add_row "icmp_ping" "$(bad)" "loss n/a, rtt ${rtt} ms"
    fi
  fi
}

test_tcp_connect() {
  if ! have nc; then
    add_row "tcp_connect" "$(warn)" "$(translate_missing nc "netcat-openbsd")"
    return
  fi
  local okc=0 i
  local min=999999 avg=0 max=0
  for ((i=1;i<=TCP_CONNECT_TRIES;i++)); do
    local t0 t1 dt
    t0=$(date +%s%3N 2>/dev/null || date +%s)
    if timeout "$TCP_CONNECT_TIMEOUT" nc -vz "$HOST" "$TCP_ECHO_PORT" >/dev/null 2>&1; then
      t1=$(date +%s%3N 2>/dev/null || date +%s)
      dt=$((t1 - t0))
      okc=$((okc+1))
      (( dt < min )) && min=$dt
      (( dt > max )) && max=$dt
      avg=$((avg + dt))
    fi
  done
  if (( okc > 0 )); then
    avg=$((avg / okc))
    add_row "tcp_connect" "$(ok)" "ok ${okc}/${TCP_CONNECT_TRIES}, min=${min}ms avg=${avg}ms max=${max}ms"
  else
    add_row "tcp_connect" "$(bad)" "no connects succeeded"
  fi
}

test_tcp_echo() {
  if ! have nc; then
    add_row "tcp_echo" "$(warn)" "$(translate_missing nc "netcat-openbsd")"
    return
  fi
  local token="ehinium_$(date +%s)_$RANDOM"
  run_with_spinner "tcp_echo" bash -lc "printf '%s\n' '$token' | timeout $CMD_TIMEOUT nc '$HOST' '$TCP_ECHO_PORT' | head -n 1"
  local rc=$?
  local resp; resp=$(head -n 1 "$RUN_OUT_FILE" | tr -d '\r\n')
  if [[ "$rc" -eq 0 && "$resp" == "$token" ]]; then
    add_row "tcp_echo" "$(ok)" "payload echoed ok"
  else
    add_row "tcp_echo" "$(bad)" "payload echo failed"
  fi
}

udp_echo_python() {
  python3 - <<PY
import socket, sys
host="${HOST}"
port=int(${UDP_ECHO_PORT})
token=${1!r}
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(${CMD_TIMEOUT})
s.sendto(token.encode(), (host, port))
data,_=s.recvfrom(4096)
sys.stdout.write(data.decode(errors="ignore"))
PY
}

test_udp_echo() {
  local token="ehinium_$(date +%s)_$RANDOM"

  if have socat; then
    run_with_spinner "udp_echo" bash -lc "printf '%s' '$token' | timeout $CMD_TIMEOUT socat - UDP:'$HOST':$UDP_ECHO_PORT,connect-timeout=2,readbytes=256 2>/dev/null | head -c ${#token}"
    local rc=$?
    local resp; resp=$(cat "$RUN_OUT_FILE")
    if [[ "$rc" -eq 0 && "$resp" == "$token" ]]; then
      add_row "udp_echo" "$(ok)" "payload echoed ok"
    else
      add_row "udp_echo" "$(bad)" "payload echo failed"
    fi
    return
  fi

  if have python3; then
    run_with_spinner "udp_echo" bash -lc "python3 - <<'PY'\nimport socket, sys\nhost='${HOST}'\nport=int('${UDP_ECHO_PORT}')\ntoken='${token}'\ns=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\ns.settimeout(${CMD_TIMEOUT})\ns.sendto(token.encode(), (host, port))\ntry:\n  data,_=s.recvfrom(4096)\n  sys.stdout.write(data.decode(errors='ignore'))\nexcept Exception:\n  pass\nPY\n"
    local resp; resp=$(cat "$RUN_OUT_FILE")
    if [[ "$resp" == "$token" ]]; then
      add_row "udp_echo" "$(ok)" "payload echoed ok"
    else
      add_row "udp_echo" "$(bad)" "payload echo failed"
    fi
    return
  fi

  add_row "udp_echo" "$(warn)" "$(translate_missing socat "apt install socat (or install python3)")"
}

test_tls_handshake() {
  if ! have openssl; then
    add_row "tls_handshake" "$(warn)" "$(translate_missing openssl "apt install openssl")"
    return
  fi
  local sni_arg=()
  [[ -n "$SNI" ]] && sni_arg=(-servername "$SNI")

  run_with_spinner "tls_handshake" timeout "$CMD_TIMEOUT" openssl s_client -connect "${HOST}:${TLS_PORT}" "${sni_arg[@]}" -brief </dev/null
  local rc=$?
  if [[ "$rc" -eq 0 ]]; then
    add_row "tls_handshake" "$(ok)" "handshake ok"
  else
    local msg
    msg=$(grep -iE -m1 "unable|refused|timed out|no route|handshake|alert|error" "$RUN_ERR_FILE" "$RUN_OUT_FILE" 2>/dev/null | head -n1 || true)
    [[ -z "$msg" ]] && msg="handshake failed"
    add_row "tls_handshake" "$(bad)" "$msg"
  fi
}

parse_iperf_receiver() {
  # prints: "<value> <unit>" or empty
  awk '/receiver/ && /bits\/sec/ {print $(NF-2), $(NF-1); exit}' "$1"
}

iperf_is_zero() {
  # $1 numeric, $2 unit
  local v="$1" u="$2"
  # treat 0 or 0.00 as zero
  awk -v v="$v" 'BEGIN{exit !(v==0)}' && return 0
  # if unit is bits/sec and value small? keep non-zero
  return 1
}

test_iperf_tcp() {
  if ! have iperf3; then
    add_row "iperf3_tcp" "$(warn)" "$(translate_missing iperf3 "apt install iperf3")"
    return
  fi
  run_with_spinner "iperf3_tcp" timeout $((IPERF_TIME + 5)) iperf3 -c "$HOST" -p "$IPERF_PORT" -t "$IPERF_TIME" -P "$IPERF_PARALLEL"
  local rc=$?

  if [[ "$rc" -ne 0 ]]; then
    local msg
    msg=$(grep -iE -m1 "unable|refused|timed out|no route|error|failed" "$RUN_ERR_FILE" "$RUN_OUT_FILE" 2>/dev/null | head -n1 || true)
    [[ -z "$msg" ]] && msg="iperf3 failed"
    add_row "iperf3_tcp" "$(bad)" "$msg"
    return
  fi

  local rx; rx=$(parse_iperf_receiver "$RUN_OUT_FILE" || true)
  if [[ -z "$rx" ]]; then
    add_row "iperf3_tcp" "$(bad)" "receiver line missing"
    return
  fi
  local val unit
  val=$(awk '{print $1}' <<< "$rx")
  unit=$(awk '{print $2}' <<< "$rx")
  if awk -v v="$val" 'BEGIN{exit !(v==0)}'; then
    add_row "iperf3_tcp" "$(bad)" "receiver $rx"
  else
    add_row "iperf3_tcp" "$(ok)" "receiver $rx"
  fi
}

test_iperf_udp() {
  if ! have iperf3; then
    add_row "iperf3_udp" "$(warn)" "$(translate_missing iperf3 "apt install iperf3")"
    return
  fi
  run_with_spinner "iperf3_udp" timeout $((IPERF_TIME + 5)) iperf3 -u -c "$HOST" -p "$IPERF_PORT" -t "$IPERF_TIME" -b "$IPERF_UDP_BW"
  local rc=$?

  if [[ "$rc" -ne 0 ]]; then
    local msg
    msg=$(grep -iE -m1 "unable|refused|timed out|no route|error|failed" "$RUN_ERR_FILE" "$RUN_OUT_FILE" 2>/dev/null | head -n1 || true)
    [[ -z "$msg" ]] && msg="iperf3 failed"
    add_row "iperf3_udp" "$(bad)" "$msg"
    return
  fi

  local sum; sum=$(awk '/receiver/ && /%/ {print; exit}' "$RUN_OUT_FILE" || true)
  if [[ -z "$sum" ]]; then
    add_row "iperf3_udp" "$(bad)" "receiver summary missing"
    return
  fi
  local rate jitter loss pct
  rate=$(awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) {print $(i-1), $i; exit}}' <<< "$sum")
  jitter=$(awk '{for(i=1;i<=NF;i++) if($i=="ms") {print $(i-1), "ms"; exit}}' <<< "$sum")
  loss=$(grep -oE '[0-9]+/[0-9]+ \([0-9.]+%\)' <<< "$sum" | head -n1 || true)
  pct=$(grep -oE '\([0-9.]+%\)' <<< "$loss" | tr -d '()%' || true)

  if [[ -z "$pct" ]]; then
    add_row "iperf3_udp" "$(warn)" "$rate, summary incomplete"
    return
  fi

  if awk -v p="$pct" 'BEGIN{exit !(p<=1.0)}'; then
    add_row "iperf3_udp" "$(ok)" "$rate, loss $loss, jitter $jitter"
  elif awk -v p="$pct" 'BEGIN{exit !(p<=3.0)}'; then
    add_row "iperf3_udp" "$(warn)" "$rate, loss $loss, jitter $jitter"
  else
    add_row "iperf3_udp" "$(bad)" "$rate, loss $loss, jitter $jitter"
  fi
}

soak_progress_line() {
  # label, attempt, total, drops
  local label="$1" i="$2" n="$3" drops="$4" start_ts="$5"
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - start_ts))
  printf "\r%s[%02d:%02d] %s %d/%d (drops=%d)%s" "${C_DIM}" $((elapsed/60)) $((elapsed%60)) "$label" "$i" "$n" "$drops" "${C_RESET}" >&2
}

test_tcp_soak() {
  if ! have nc; then
    add_row "tcp_soak" "$(warn)" "$(translate_missing nc "netcat-openbsd")"
    return
  fi
  local drops=0 first=0 i
  local start_ts; start_ts=$(date +%s)
  for ((i=1;i<=SOAK_LOOPS;i++)); do
    soak_progress_line "tcp_soak" "$i" "$SOAK_LOOPS" "$drops" "$start_ts"
    if ! timeout "$SOAK_TIMEOUT" nc -vz "$HOST" "$TCP_ECHO_PORT" >/dev/null 2>&1; then
      drops=$((drops+1)); [[ "$first" -eq 0 ]] && first="$i"
    fi
    sleep "$SOAK_INTERVAL"
  done
  printf "\r%s[%02d:%02d] tcp_soak done%s\n" "${C_DIM}" $((( $(date +%s) - start_ts )/60)) $((( $(date +%s) - start_ts )%60)) "${C_RESET}" >&2

  if (( drops == 0 )); then
    add_row "tcp_soak" "$(ok)" "ok ${SOAK_LOOPS}/${SOAK_LOOPS}, no drops"
  else
    add_row "tcp_soak" "$(warn)" "drops ${drops}/${SOAK_LOOPS}, first drop at attempt ${first}"
  fi
}

test_tls_soak() {
  if ! have openssl; then
    add_row "tls_soak" "$(warn)" "$(translate_missing openssl "apt install openssl")"
    return
  fi
  local sni_arg=(); [[ -n "$SNI" ]] && sni_arg=(-servername "$SNI")
  local drops=0 first=0 i
  local start_ts; start_ts=$(date +%s)
  for ((i=1;i<=SOAK_LOOPS;i++)); do
    soak_progress_line "tls_soak" "$i" "$SOAK_LOOPS" "$drops" "$start_ts"
    if ! timeout "$SOAK_TIMEOUT" openssl s_client -connect "${HOST}:${TLS_PORT}" "${sni_arg[@]}" -brief </dev/null >/dev/null 2>&1; then
      drops=$((drops+1)); [[ "$first" -eq 0 ]] && first="$i"
    fi
    sleep "$SOAK_INTERVAL"
  done
  printf "\r%s[%02d:%02d] tls_soak done%s\n" "${C_DIM}" $((( $(date +%s) - start_ts )/60)) $((( $(date +%s) - start_ts )%60)) "${C_RESET}" >&2

  if (( drops == 0 )); then
    add_row "tls_soak" "$(ok)" "ok ${SOAK_LOOPS}/${SOAK_LOOPS}, no drops"
  else
    add_row "tls_soak" "$(bad)" "drops ${drops}/${SOAK_LOOPS}, first drop at attempt ${first}"
  fi
}

run_suite_client_single_host() {
  reset_table
  show_params

  case "$SUITE" in
    express)
      test_icmp_ping
      test_tcp_connect
      test_tcp_echo
      test_udp_echo
      test_tls_handshake
      test_iperf_tcp
      test_iperf_udp
      test_tcp_soak
      test_tls_soak
      ;;
    baseline)
      test_icmp_ping
      test_tcp_connect
      test_tcp_echo
      test_udp_echo
      test_tls_handshake
      ;;
    throughput)
      test_iperf_tcp
      test_iperf_udp
      ;;
    soak)
      test_tcp_soak
      test_tls_soak
      ;;
    custom)
      prompt_choice "Select tests to run:" \
        "Baseline (icmp + connect + echo + tls)" \
        "Throughput (iperf3 tcp + udp)" \
        "Soak (tcp + tls soak)" \
        "All (everything)"
      case "$CHOICE_INDEX" in
        0) SUITE="baseline" ;;
        1) SUITE="throughput" ;;
        2) SUITE="soak" ;;
        3) SUITE="express" ;;
      esac
      run_suite_client_single_host
      return
      ;;
  esac

  if [[ "$OUTPUT_FORMAT" == "markdown" ]]; then
    print_table_markdown
  else
    print_table_terminal
  fi
  maybe_write_tsv
}

run_suite_client_multi_hosts_if_needed() {
  if (( ${#HOSTS[@]} > 0 )); then
    local h
    for h in "${HOSTS[@]}"; do
      HOST="$h"
      printf "\n%s\n" "${C_BOLD}${C_MAG}Target: ${HOST}${C_RESET}"
      run_suite_client_single_host
    done
  else
    run_suite_client_single_host
  fi
}

# -----------------------------
# Interactive wizard
# -----------------------------
print_banner_once() {
  clear 2>/dev/null || true
  cat << "EOF" 
      _     _       _                   _   _      _   ____            _          
   ___| |__ (_)_ __ (_)_   _ _ __ ___   | \ | | ___| |_|  _ \ _ __ ___ | |__   ___ 
  / _ \ '_ \| | '_ \| | | | | '_ ` _ \  |  \| |/ _ \ __| |_) | '__/ _ \| '_ \ / _ \
 |  __/ | | | | | | | | |_| | | | | | | | |\  |  __/ |_|  __/| | | (_) | |_) |  __/
  \___|_| |_|_|_| |_|_|\__,_|_| |_| |_| |_| \_|\___|\__|_|   |_|  \___/|_.__/ \___|

EOF
  printf "%s\n" "${C_MAG}${C_BOLD}ehiniumNetProbe${C_RESET}"
  printf "%s\n" "Version ${C_YELLOW}${VERSION}${C_RESET}"
  printf "%s\n" "Github ${C_YELLOW}github.com/ehinium/ehiniumNetProbe${C_RESET}"
  printf "%s\n" "By Ehsan ${C_YELLOW}@ehinium${C_RESET}"
}

wizard_loop() {
  print_banner_once

  while true; do
    prompt_choice "Choose a test type:" \
      "Express Test" \
      "Baseline Connectivity Test" \
      "Throughput Test" \
      "Stability Soak Test" \
      "Custom Test"
    case "$CHOICE_INDEX" in
      0) SUITE="express" ;;
      1) SUITE="baseline" ;;
      2) SUITE="throughput" ;;
      3) SUITE="soak" ;;
      4) SUITE="custom" ;;
    esac

    prompt_choice "Select mode:" "Client" "Server"
    [[ "$CHOICE_INDEX" -eq 0 ]] && MODE="client" || MODE="server"

    HOSTS=(); HOST=""; SNI=""

    if [[ "$MODE" == "client" ]]; then
      if [[ "$SUITE" == "baseline" || "$SUITE" == "throughput" ]]; then
        while true; do
          prompt_line_nonempty "Target host(s) (comma separated): "
          parse_hosts_csv "$PROMPT_VALUE"
          if (( ${#HOSTS[@]} == 0 )); then
            err "No hosts detected. Example: 1.1.1.1,8.8.8.8"
            continue
          fi
          local badh=""
          local h
          for h in "${HOSTS[@]}"; do
            if ! is_valid_host "$h"; then badh="$h"; break; fi
          done
          if [[ -n "$badh" ]]; then
            err "Invalid host: $badh"
            continue
          fi
          break
        done
      else
        while true; do
          prompt_line_nonempty "Target host (IP or domain): "
          HOST="$PROMPT_VALUE"
          if is_valid_host "$HOST"; then break; fi
          err "Invalid host. Use IP or hostname characters only."
        done
      fi

      prompt_line_default "SNI (optional, press Enter to skip): " ""
      SNI="$PROMPT_VALUE"
    fi

    if [[ "$SUITE" == "custom" ]]; then
      prompt_line_default "TCP echo port [$TCP_ECHO_PORT]: " "$TCP_ECHO_PORT"; TCP_ECHO_PORT="$PROMPT_VALUE"
      prompt_line_default "UDP echo port [$UDP_ECHO_PORT]: " "$UDP_ECHO_PORT"; UDP_ECHO_PORT="$PROMPT_VALUE"
      prompt_line_default "TLS port [$TLS_PORT]: " "$TLS_PORT"; TLS_PORT="$PROMPT_VALUE"
      prompt_line_default "iperf3 port [$IPERF_PORT]: " "$IPERF_PORT"; IPERF_PORT="$PROMPT_VALUE"
      prompt_line_default "Soak loops [$SOAK_LOOPS]: " "$SOAK_LOOPS"; SOAK_LOOPS="$PROMPT_VALUE"
      prompt_line_default "Soak interval seconds [$SOAK_INTERVAL]: " "$SOAK_INTERVAL"; SOAK_INTERVAL="$PROMPT_VALUE"
      prompt_line_default "iperf3 UDP bandwidth [$IPERF_UDP_BW]: " "$IPERF_UDP_BW"; IPERF_UDP_BW="$PROMPT_VALUE"

      prompt_choice "Output format:" "Terminal table" "Markdown table"
      OUTPUT_FORMAT=$([[ "$CHOICE_INDEX" -eq 1 ]] && echo "markdown" || echo "terminal")

      prompt_choice "Write TSV file?" "No" "Yes"
      if [[ "$CHOICE_INDEX" -eq 1 ]]; then
        prompt_line_nonempty "TSV output path: "
        TSV_OUT="$PROMPT_VALUE"
      else
        TSV_OUT=""
      fi
    else
      OUTPUT_FORMAT="terminal"
      TSV_OUT=""
    fi

    if [[ "$MODE" == "server" ]]; then
      server_mode
      return
    else
      run_suite_client_multi_hosts_if_needed
      pause_to_menu
    fi
  done
}

# -----------------------------
# CLI parsing
# -----------------------------
usage() {
  cat <<EOF
Usage:
  $0                (interactive)
  $0 --interactive  (interactive)

  $0 server --suite baseline|throughput|soak|express|custom
  $0 client --suite baseline|throughput|soak|express|custom --host <ip|domain> [--sni <name>]

Custom-only:
  --format terminal|markdown
  --tsv <path>
EOF
}

parse_args() {
  if [[ $# -eq 0 ]]; then wizard_loop; exit 0; fi
  if [[ "${1:-}" == "--interactive" || "${1:-}" == "-i" ]]; then wizard_loop; exit 0; fi

  MODE="$1"; shift || true
  if [[ "$MODE" != "client" && "$MODE" != "server" ]]; then usage; err "First arg must be client or server (or run interactive)."; exit 1; fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --suite) SUITE="${2:-}"; shift 2 ;;
      --host) HOST="${2:-}"; shift 2 ;;
      --sni)  SNI="${2:-}"; shift 2 ;;
      --format) OUTPUT_FORMAT="${2:-terminal}"; shift 2 ;;
      --tsv) TSV_OUT="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  if [[ "$SUITE" != "custom" ]]; then OUTPUT_FORMAT="terminal"; TSV_OUT=""; fi

  if [[ "$MODE" == "client" ]]; then
    [[ -z "${HOST:-}" ]] && { err "--host is required in client mode"; exit 1; }
    if ! is_valid_host "$HOST"; then err "Invalid host"; exit 1; fi
    HOSTS=()
    run_suite_client_single_host
  else
    server_mode
  fi
}

parse_args "$@"