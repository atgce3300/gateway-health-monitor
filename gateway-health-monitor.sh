#!/bin/bash
#
# Gateway Health Monitor
# Monitors gateway connectivity, detects disconnections, logs health + root causes
# Works with or without PM2
#

#  ^t^` ^t^` Config  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` >
LOG_DIR="$HOME/.openclaw/workspace/logs"
HEALTH_LOG="${LOG_DIR}/gateway-health.log"
DISCONNECT_LOG="${LOG_DIR}/gateway-disconnects.log"
STATE_FILE="/tmp/openclaw-monitor-state.json"
CHECK_INTERVAL_SECS=30
MAX_LOG_LINES=20000
AUTO_RESTART=false
RESTART_COOLDOWN_SECS=300
MAX_CONSECUTIVE_FAILS=3

# Gateway process
GATEWAY_BINARY="openclaw"
GATEWAY_HOST="127.0.0.1" #changed from 127.0.0.1 to XXX.XX.XXX.XX, but it is 127.0.0.1 for this device so it is 127.0.0.1
GATEWAY_PORT=18789 #changed from 18789 to 18791 on 11 July 2026, but it is 18789 for this device so it is 18789
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
API_TIMEOUT_SECS=5

# Health check mode: "http" (curl endpoints), "port" (tcp check), "ws" (websocket upgrade), "skip"
HEALTH_CHECK_MODE="port"
HEALTH_ENDPOINTS=("/health" "/api/health" "/")
WS_CHECK_PATH="/"

# PM2
PM2_PROCESS_NAME="gateway"
PM2_LOG_DIR="$HOME/.pm2/logs"
PM2_OUT_LOG="${PM2_LOG_DIR}/${PM2_PROCESS_NAME}-out.log"
PM2_ERR_LOG="${PM2_LOG_DIR}/${PM2_PROCESS_NAME}-error.log"

# Gateway runtime logs (resolved to today automatically)
OPENCLAW_RUNTIME_LOG_DIR="/tmp/openclaw"

# Restart tuning
KILL_WAIT_SECS=2
# Log scanning
DISCORD_LOG_TAIL_LINES=200
REASON_LOG_TAIL_LINES=500
FAILURE_CONTEXT_LINES=20

# Health log verbosity (log OK every N checks)
HEALTH_LOG_EVERY_N_CHECKS=10

#  ^t^` ^t^` Ensure dirs exist  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^`>
mkdir -p "$LOG_DIR"

#  ^t^` ^t^` State  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^>
LAST_RESTART_TS=0
CONSECUTIVE_FAILS=0
LAST_STATUS="unknown"
#  ^t^` ^t^` Helpers  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^`>
ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_health() {
  echo "[$(ts)] $1" >> "$HEALTH_LOG"
}

log_disconnect() {
  echo "[$(ts)] $1" >> "$DISCONNECT_LOG"
}

trim_log() {
  local file="$1"
  if [[ -f "$file" ]] && (( $(wc -l < "$file") > MAX_LOG_LINES )); then
    tail -n $((MAX_LOG_LINES / 2)) "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}

save_state() {
  printf '{"last_restart_ts":%d,"consecutive_fails":%d,"last_status":"%s"}\n' \
    "$LAST_RESTART_TS" "$CONSECUTIVE_FAILS" "$LAST_STATUS" > "$STATE_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    LAST_RESTART_TS=$(jq -r '.last_restart_ts // 0' "$STATE_FILE")
    CONSECUTIVE_FAILS=$(jq -r '.consecutive_fails // 0' "$STATE_FILE")
    LAST_STATUS=$(jq -r '.last_status // "unknown"' "$STATE_FILE")
  fi
}

# Resolve which gateway log to read (priority order)
resolve_gateway_log() {
  local today
  today=$(date '+%Y-%m-%d')

  # 1. PM2 out log (if PM2-managed)
  if is_pm2_managed &>/dev/null && [[ -f "$PM2_OUT_LOG" ]]; then
    echo "$PM2_OUT_LOG"
    return
  fi

  # 2. Gateway runtime log for today
  local runtime_log="${OPENCLAW_RUNTIME_LOG_DIR}/openclaw-${today}.log"
  if [[ -f "$runtime_log" ]]; then
    echo "$runtime_log"
    return
  fi

  # 3. Fallback: legacy static path
  local fallback="${LOG_DIR}/gateway.log"
  if [[ -f "$fallback" ]]; then
    echo "$fallback"
    return
  fi

  echo ""
}
#  ^t^` ^t^` Detection Functions  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t>

is_pm2_managed() {
  command -v pm2 &>/dev/null && \
    pm2 jlist 2>/dev/null | jq -e --arg name "$PM2_PROCESS_NAME" \
      '[.[] | select(.name == $name)] | length > 0' 2>/dev/null
}

is_process_running() {
  pgrep -f "$GATEWAY_BINARY" &>/dev/null
}

# Check if PM2's child process (actual gateway) is still alive
# PM2 may report "online" for the bash wrapper while the real process is dead
is_pm2_child_alive() {
  local pm2_pid
  pm2_pid=$(pm2 jlist 2>/dev/null | jq --arg name "$PM2_PROCESS_NAME" \
    '[.[] | select(.name == $name)][0].pid' 2>/dev/null)

  if [[ -z "$pm2_pid" || "$pm2_pid" == "null" ]]; then
    return 1
  fi

  # Check if the PM2 wrapper has any children
  local children
  children=$(pgrep -P "$pm2_pid" 2>/dev/null)

  if [[ -n "$children" ]]; then
    return 0
  fi
  # No children  ^`^t check if PM2 process itself IS the gateway (not a wrapper)
  local cmd
  cmd=$(cat "/proc/${pm2_pid}/cmdline" 2>/dev/null | tr '\0' ' ')
  if echo "$cmd" | grep -q "$GATEWAY_BINARY"; then
    return 0
  fi

  # Wrapper alive but real gateway is dead
  return 1
}

is_api_responsive() {
  local port
  port=$(jq -r ".gateway.port // $GATEWAY_PORT" "$OPENCLAW_CONFIG" 2>/dev/null || echo "$GATEWAY_PORT")
  case "$HEALTH_CHECK_MODE" in
    http)
      for endpoint in "${HEALTH_ENDPOINTS[@]}"; do
        if curl -sf --max-time "$API_TIMEOUT_SECS" "http://${GATEWAY_HOST}:${port}${endpoint}" &>/dev/null; then
          return 0
        fi
      done
      return 1
      ;;
    port)
      # TCP port check  ^`^t works even when no REST endpoints exist
      if command -v nc &>/dev/null; then
        nc -z -w "$API_TIMEOUT_SECS" "$GATEWAY_HOST" "$port" &>/dev/null
      else
        # Fallback: bash /dev/tcp
        (echo >/dev/tcp/"$GATEWAY_HOST"/"$port") &>/dev/null
      fi
      ;;
    ws)
      # WebSocket upgrade handshake check
      curl -sf --max-time "$API_TIMEOUT_SECS" \
        -H "Upgrade: websocket" \
        -H "Connection: Upgrade" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        "http://${GATEWAY_HOST}:${port}${WS_CHECK_PATH}" &>/dev/null
      ;;
    skip)
      return 0
      ;;
    *)
      log_health "WARNING: unknown HEALTH_CHECK_MODE, defaulting to port"
      if command -v nc &>/dev/null; then
        nc -z -w "$API_TIMEOUT_SECS" "$GATEWAY_HOST" "$port" &>/dev/null
      else
        (echo >/dev/tcp/"$GATEWAY_HOST"/"$port") &>/dev/null
      fi
      ;;
  esac
}

discord_status() {
  local log_file
  log_file=$(resolve_gateway_log)
  if [[ -z "$log_file" || ! -f "$log_file" ]]; then
    echo "no_log"
    return
  fi
  local recent
  recent=$(tail -n "$DISCORD_LOG_TAIL_LINES" "$log_file" 2>/dev/null)

  if echo "$recent" | grep -qi "client initialized"; then
    echo "connected"
  elif echo "$recent" | grep -qi "disconnected\|connection lost\|reconnecting"; then
    echo "disconnected"
  elif echo "$recent" | grep -qi "error.*discord\|ECONNRESET\|ETIMEDOUT"; then
    echo "error"
  else
    echo "unknown"
  fi
}

find_disconnect_reason() {
  local log_file
  log_file=$(resolve_gateway_log)
  if [[ -z "$log_file" || ! -f "$log_file" ]]; then
    echo "no_gateway_log_found"
    return
  fi

  local recent
  recent=$(tail -n "$REASON_LOG_TAIL_LINES" "$log_file" 2>/dev/null)

  if echo "$recent" | grep -qi "OOM\|out of memory\|killed.*signal 9\|Cannot allocate memory"; then
    echo "OOM_KILL"
  elif echo "$recent" | grep -qi "SIGTERM\|graceful shutdown\|received SIGTERM"; then
    echo "SIGTERM_manual_stop"
  elif echo "$recent" | grep -qi "unhandledRejection\|uncaughtException"; then
    echo "UNHANDLED_EXCEPTION"
  elif echo "$recent" | grep -qi "ECONNRESET\|ETIMEDOUT\|ECONNREFUSED.*discord"; then
    echo "DISCORD_NETWORK_ERROR"
  elif echo "$recent" | grep -qi "ENOTFOUND\|getaddrinfo"; then
    echo "DNS_FAILURE_network_down"
  elif echo "$recent" | grep -qi "429\|rate.limit\|rate limited"; then
    echo "API_RATE_LIMITED"
  elif echo "$recent" | grep -qi "EADDRINUSE"; then
    echo "PORT_CONFLICT"
  elif echo "$recent" | grep -qi "SIGSEGV\|segmentation fault"; then
    echo "SEGFAULT"
  elif echo "$recent" | grep -qi "partial Channel\|rawData"; then
    echo "plugin_error_partial_channel"
  elif echo "$recent" | grep -qi "crash\|fatal\|panic"; then
    echo "CRASH_fatal_error"
  else
    echo "unknown_check_logs"
  fi
}

pm2_status() {
  if ! command -v pm2 &>/dev/null; then
    echo "not_installed"
    return
  fi
  local info
  info=$(pm2 jlist 2>/dev/null | jq --arg name "$PM2_PROCESS_NAME" \
    '[.[] | select(.name == $name)] | .[0]' 2>/dev/null)
  if [[ -z "$info" || "$info" == "null" ]]; then
    echo "not_managed"
    return
  fi
  echo "$info" | jq -r \
    '"\(.pm2_env.status) | restarts:\(.pm2_env.restart_time) | uptime:\(.pm2_env.pm_uptime) | mem:\(.monit.memory / 1048576 | floor)MB | cpu:\(.monit.cpu)%"' \
    2>/dev/null
}

#  ^t^` ^t^` Restart Logic  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^>
attempt_restart() {
  local now
  now=$(date +%s)
  local cooldown_remaining=$(( now - LAST_RESTART_TS ))

  if (( cooldown_remaining < RESTART_COOLDOWN_SECS )); then
    local wait=$(( RESTART_COOLDOWN_SECS - cooldown_remaining ))
    log_disconnect "RESTART_SKIPPED: cooldown active, ${wait}s remaining"
    return 1
  fi

  log_disconnect "ATTEMPTING_RESTART: reason=$1"
  LAST_RESTART_TS=$now

  if is_pm2_managed &>/dev/null; then
    pm2 restart "$PM2_PROCESS_NAME" 2>&1 | while read -r line; do
      log_disconnect "PM2_RESTART: $line"
    done
  else
    pkill -f "$GATEWAY_BINARY" 2>/dev/null
    sleep "$KILL_WAIT_SECS"
    nohup openclaw gateway start >> "$(resolve_gateway_log)" 2>&1 &
    log_disconnect "DIRECT_RESTART: launched via nohup"
  fi

  save_state
  return 0
}

#  ^t^` ^t^` Main Loop  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t>
load_state
log_health "MONITOR_STARTED: interval=${CHECK_INTERVAL_SECS}s, auto_restart=${AUTO_RESTART}, health_check=${HEALTH_CHECK_MODE}"
while true; do
  process_ok=false
  api_ok=false
  pm2_ok=false
  discord_ok=false
  status="healthy"
  issues=()

  # 1. Process check
  if is_process_running; then
    process_ok=true
  else
    status="down"
    issues+=("process_not_running")
  fi
  # 2. API / port check
  if $process_ok && is_api_responsive; then
    api_ok=true
  elif $process_ok; then
    status="degraded"
    issues+=("api_not_responsive")
  fi

  # 3. PM2 check (including child process liveness)
  pm2_managed=false
  if is_pm2_managed &>/dev/null; then
    pm2_managed=true
    local_pm2_status=$(pm2_status)
    if echo "$local_pm2_status" | grep -qi "stopped\|errored\|stopping"; then
      pm2_ok=false
      status="degraded"
      issues+=("pm2_status_abnormal: $local_pm2_status")
    elif ! is_pm2_child_alive; then
      pm2_ok=false
      status="degraded"
      issues+=("pm2_child_dead: wrapper alive but gateway process gone")
    else
      pm2_ok=true
    fi
  fi


  # 4. Discord check
  discord_state=$(discord_status)
  if [[ "$discord_state" == "connected" ]]; then
    discord_ok=true
  elif [[ "$discord_state" == "disconnected" || "$discord_state" == "error" ]]; then
    if [[ "$status" == "healthy" ]]; then
      status="degraded"
    fi
    issues+=("discord_${discord_state}")
  fi

  #  ^t^` ^t^` Determine action  ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^` ^t^>
  if [[ "$status" == "healthy" ]]; then
    CONSECUTIVE_FAILS=0
    if (( SECONDS % (CHECK_INTERVAL_SECS * HEALTH_LOG_EVERY_N_CHECKS) < CHECK_INTERVAL_SECS )); then
      pm2_info=""
      $pm2_managed && pm2_info=" | pm2: $(pm2_status)"
      log_health "OK | discord:${discord_state}${pm2_info}"
    fi
  else
    CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
    reason="n/a"
    if [[ "$status" == "down" ]]; then
      reason=$(find_disconnect_reason)
    fi

    issue_str=$(IFS=','; echo "${issues[*]}")
    log_health "FAIL #${CONSECUTIVE_FAILS} | status:${status} | issues:${issue_str} | reason:${reason}"
    log_disconnect "DISCONNECT_DETECTED | status:${status} | issues:${issue_str} | reason:${reason} | pm2:${pm2_managed}"

    # Append recent relevant log lines for context
    local_gw_log=$(resolve_gateway_log)
    if [[ -n "$local_gw_log" && -f "$local_gw_log" ]]; then
      log_disconnect "--- Recent gateway log ---"
      tail -n "$FAILURE_CONTEXT_LINES" "$local_gw_log" | grep -i "error\|warn\|disconnect\|crash\|kill\|signal\|fatal" >> "$DISCONNECT_LOG" 2>/dev/null
      log_disconnect "--- End recent log ---"
    fi

    # Auto-restart if enabled and threshold reached
    if $AUTO_RESTART && (( CONSECUTIVE_FAILS >= MAX_CONSECUTIVE_FAILS )); then
      attempt_restart "$reason"
    fi
  fi

  LAST_STATUS="$status"
  save_state
  trim_log "$HEALTH_LOG"
  trim_log "$DISCONNECT_LOG"
  sleep "$CHECK_INTERVAL_SECS"
done


