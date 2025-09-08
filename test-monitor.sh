#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

STATE_DIR="/var/run/test-monitor"
LOCK_FILE="${STATE_DIR}/lock"
STATE_FILE="${STATE_DIR}/.last_starttime"
LOG_FILE="/var/log/monitoring.log"
MONITORING_URL_DEFAULT="https://test.com/monitoring/test/api"
MONITORING_URL="${MONITORING_URL:-${MONITORING_URL_DEFAULT}}"

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_line() {
  local level="$1" event="$2" pid="$3" st="$4" detail="${5//$'\n'/ }"
  detail="${detail//\"/\\\"}"
  printf '%s %s event=%s pid=%s starttime=%s detail="%s"\n' \
    "$(ts_utc)" "$level" "$event" "$pid" "$st" "$detail" >>"$LOG_FILE"
}

fatal() {
  local msg="$1"
  if [[ -w "$LOG_FILE" ]]; then
    log_line "ERROR" "monitoring_error" "-" "-" "script_error: $msg"
  else
    printf '%s ERROR event=monitoring_error pid=- starttime=- detail="script_error: %s"\n' \
      "$(ts_utc)" "$msg" >&2 || true
  fi
  exit 1
}

ensure_paths() {
  mkdir -p "$STATE_DIR" || fatal "cannot create $STATE_DIR"
  chmod 0755 "$STATE_DIR" || fatal "cannot chmod $STATE_DIR"
  : >"$LOCK_FILE" || fatal "cannot touch $LOCK_FILE"
  chmod 0644 "$LOCK_FILE" || fatal "cannot chmod $LOCK_FILE"
  if [[ ! -e "$LOG_FILE" ]]; then
    : >"$LOG_FILE" || fatal "cannot create $LOG_FILE"
  fi
  chmod 0644 "$LOG_FILE" || fatal "cannot chmod $LOG_FILE"
}

find_oldest_test_process() {
  OLDEST_PID=""
  OLDEST_STARTTIME=""
  for d in /proc/[0-9]*; do
    [[ -d "$d" ]] || continue
    local pid="${d#/proc/}"
    if [[ -r "$d/comm" ]]; then
      local comm
      IFS= read -r comm <"$d/comm" || continue
      [[ "$comm" == "test" ]] || continue
    else
      continue
    fi
    if [[ -r "$d/stat" ]]; then
      local stat_content rest pos
      stat_content="$(<"$d/stat")" || continue
      pos=-1
      for ((i=${#stat_content}-1; i>=0; i--)); do
        if [[ "${stat_content:$i:1}" == ")" ]]; then
          pos=$i; break
        fi
      done
      (( pos >= 0 )) || continue
      local next_index=$((pos+1))
      while [[ "${stat_content:$next_index:1}" == " " ]]; do ((next_index++)); done
      rest="${stat_content:$next_index}"
      local -a arr
      IFS=' ' read -r -a arr <<<"$rest"
      (( ${#arr[@]} >= 20 )) || continue
      local starttime="${arr[19]}"
      if [[ -z "$OLDEST_STARTTIME" ]] || (( starttime < OLDEST_STARTTIME )); then
        OLDEST_STARTTIME="$starttime"
        OLDEST_PID="$pid"
      fi
    fi
  done
}

perform_monitoring_request() {
  local url="$1"
  local http_code curl_rc err_file err_text
  err_file="$(mktemp -t test-monitor.XXXXXX)" || fatal "mktemp failed"
  http_code="$(
    curl -sS -m 5 -o /dev/null -w "%{http_code}" -- "$url" 2>"$err_file"
  )" || true
  curl_rc=$?
  if [[ -s "$err_file" ]]; then
    err_text="$(tr -d '\n' <"$err_file" || true)"
  else
    err_text=""
  fi
  rm -f "$err_file" || true
  if (( curl_rc != 0 )); then
    log_line "ERROR" "monitoring_error" "${OLDEST_PID:-"-"}" "${OLDEST_STARTTIME:-"-"}" \
      "curl_exit=$curl_rc ${err_text:-"(no stderr)"}"
    return 0
  fi
  if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
    log_line "ERROR" "monitoring_error" "${OLDEST_PID:-"-"}" "${OLDEST_STARTTIME:-"-"}" \
      "http_status=$http_code"
  fi
}

main() {
  command -v curl >/dev/null 2>&1 || fatal "curl is required"
  ensure_paths
  trap 'fatal "unexpected error on line $LINENO"' ERR
  exec 9>"$LOCK_FILE" || fatal "cannot open lock file"
  if ! flock -n 9; then exit 0; fi
  find_oldest_test_process
  if [[ -z "${OLDEST_PID:-}" || -z "${OLDEST_STARTTIME:-}" ]]; then exit 0; fi
  if [[ ! -e "$STATE_FILE" ]]; then
    printf '%s\n' "$OLDEST_STARTTIME" >"$STATE_FILE" || fatal "cannot write $STATE_FILE"
    chmod 0644 "$STATE_FILE"
    log_line "INFO" "started" "$OLDEST_PID" "$OLDEST_STARTTIME" "first_detection"
  else
    local prev; IFS= read -r prev <"$STATE_FILE" || prev=""
    if [[ -z "$prev" || "$prev" != "$OLDEST_STARTTIME" ]]; then
      printf '%s\n' "$OLDEST_STARTTIME" >"$STATE_FILE" || fatal "cannot update $STATE_FILE"
      log_line "INFO" "restarted" "$OLDEST_PID" "$OLDEST_STARTTIME" "process_starttime_changed prev=${prev:-"-"}"
    fi
  fi
  perform_monitoring_request "$MONITORING_URL"
}

main "$@"
