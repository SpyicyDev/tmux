#!/usr/bin/env bash

set -euo pipefail


CACHE_DIR="${HOME}/.cache/codexbar-tmux"
CACHE_FILE="${CACHE_DIR}/usage.json"
LOCKDIR="${CACHE_FILE}.lock"
BACKOFF_FILE="${CACHE_DIR}/refresh_backoff"

tmux_opt_or_empty() {
  local opt_name="${1:-}"

  command -v tmux >/dev/null 2>&1 || { printf '%s' ""; return 0; }
  [[ -n "${opt_name:-}" ]] || { printf '%s' ""; return 0; }

  tmux show-option -gqv "$opt_name" 2>/dev/null || true
}

opt_or_env_or_default() {
  local opt_name="${1:-}" env_name="${2:-}" default_value="${3:-}"

  local v
  v="$(tmux_opt_or_empty "$opt_name")"
  if [[ -n "${v:-}" ]]; then
    printf '%s' "$v"
    return 0
  fi

  if [[ -n "${env_name:-}" ]]; then
    v="${!env_name:-}"
    if [[ -n "${v:-}" ]]; then
      printf '%s' "$v"
      return 0
    fi
  fi

  printf '%s' "$default_value"
}

parse_int_with_default() {
  local raw="${1:-}" default_value="${2:-0}"

  if [[ "${raw:-}" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$raw"
  else
    printf '%s' "$default_value"
  fi

  return 0
}

clamp_int_range() {
  local raw="${1:-}" min="${2:-0}" max="${3:-0}"

  local v
  v="$(parse_int_with_default "$raw" "$min")"

  if (( v < min )); then
    v=$min
  elif (( v > max )); then
    v=$max
  fi

  printf '%s' "$v"
  return 0
}

CODEXBAR_USAGE_DEBUG="$(parse_int_with_default "$(opt_or_env_or_default '@codexbar_debug' 'CODEXBAR_USAGE_DEBUG' '0')" 0)"
USAGE_REFRESH_LOG_FILE="${CACHE_DIR}/usage-refresh.log"

STALE_AFTER_SECONDS="$(parse_int_with_default "$(opt_or_env_or_default '@codexbar_stale_after_seconds' 'CODEXBAR_USAGE_STALE_AFTER_SECONDS' '300')" 300)"

if (( CODEXBAR_USAGE_DEBUG == 0 && STALE_AFTER_SECONDS < 30 )); then
  STALE_AFTER_SECONDS=30
fi

WEB_TIMEOUT_SECONDS="$(clamp_int_range "$(opt_or_env_or_default '@codexbar_web_timeout' 'CODEXBAR_USAGE_WEB_TIMEOUT' '2')" 1 30)"

log_debug() {
  [[ -n "${CODEXBAR_USAGE_DEBUG:-}" && "${CODEXBAR_USAGE_DEBUG:-}" != "0" ]] || return 0

  mkdir -p "$CACHE_DIR" 2>/dev/null || true

  printf '%s pid=%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "${1:-}" >>"$USAGE_REFRESH_LOG_FILE" 2>/dev/null || true
}

log_debug_trunc() {
  local msg="${1:-}" max="${2:-200}"

  msg="${msg//$'\n'/\\n}"
  msg="${msg//$'\r'/}"

  if (( ${#msg} > max )); then
    msg="${msg:0:max}..."
  fi

  log_debug "$msg"
}

debug_flash_codex_icons() {
  (( CODEXBAR_USAGE_DEBUG != 0 )) || return 0
  command -v tmux >/dev/null 2>&1 || return 0

  local flash_color
  flash_color="$(tmux_opt_or_empty '@codexbar_debug_flash_color')"
  if [[ -z "${flash_color:-}" ]]; then
    flash_color='default'
  fi

  local prev_session prev_weekly nonce
  prev_session="$(tmux show-option -gqv @codex_session_color 2>/dev/null || true)"
  prev_weekly="$(tmux show-option -gqv @codex_weekly_color 2>/dev/null || true)"

  nonce="$(date +%s%N 2>/dev/null || date +%s)"

  tmux set-option -gq @codexbar_debug_flash_nonce "$nonce" >/dev/null 2>&1 || true
  tmux set-option -gq @codexbar_debug_flash_prev_session_color "$prev_session" >/dev/null 2>&1 || true
  tmux set-option -gq @codexbar_debug_flash_prev_weekly_color "$prev_weekly" >/dev/null 2>&1 || true

  tmux set-option -gq @codex_session_color "$flash_color" >/dev/null 2>&1 || true
  tmux set-option -gq @codex_weekly_color "$flash_color" >/dev/null 2>&1 || true
  tmux refresh-client -S >/dev/null 2>&1 || true
  log_debug "flash: on color=${flash_color}"

  tmux run-shell -b "sleep 0.5; n=\$(tmux show-option -gqv @codexbar_debug_flash_nonce 2>/dev/null); [ \"\$n\" = \"$nonce\" ] || exit 0; fc='$flash_color'; cs=\$(tmux show-option -gqv @codex_session_color 2>/dev/null || true); cw=\$(tmux show-option -gqv @codex_weekly_color 2>/dev/null || true); s=\$(tmux show-option -gqv @codexbar_debug_flash_prev_session_color 2>/dev/null); w=\$(tmux show-option -gqv @codexbar_debug_flash_prev_weekly_color 2>/dev/null); if [ \"\$cs\" = \"\$fc\" ]; then if [ -n \"\$s\" ]; then tmux set-option -gq @codex_session_color \"\$s\"; else tmux set-option -gu @codex_session_color; fi; fi; if [ \"\$cw\" = \"\$fc\" ]; then if [ -n \"\$w\" ]; then tmux set-option -gq @codex_weekly_color \"\$w\"; else tmux set-option -gu @codex_weekly_color; fi; fi; tmux refresh-client -S;" >/dev/null 2>&1 || true
}

script_abs_path() {
  local script="$0"
  if [[ "$script" != /* ]]; then
    script="$(cd -- "$(dirname -- "$script")" && pwd)/$(basename -- "$script")"
  fi
  printf '%s' "$script"
}

debug_flash_loop_nonce_opt='@codexbar__debug_flash_loop_nonce'
debug_update_counter_opt='@codexbar__debug_update_counter'

debug_flash_loop_enabled() {
  (( CODEXBAR_USAGE_DEBUG != 0 )) || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  (( STALE_AFTER_SECONDS > 0 )) || return 1
  return 0
}

schedule_debug_flash_tick() {
  local nonce="${1:-}" period="${2:-0}"

  [[ -n "${nonce:-}" ]] || return 0
  [[ "$period" =~ ^[0-9]+$ ]] || return 0
  (( period > 0 )) || return 0

  local script
  script="$(script_abs_path)"

  tmux run-shell -b "sleep $period; n=\$(tmux show-option -gqv $debug_flash_loop_nonce_opt 2>/dev/null || true); [ \"\$n\" = \"$nonce\" ] || exit 0; \"$script\" --debug-flash-tick \"$nonce\" >/dev/null 2>&1" >/dev/null 2>&1 || true
}

start_debug_flash_loop_if_needed() {
  command -v tmux >/dev/null 2>&1 || return 0

  if ! debug_flash_loop_enabled; then
    tmux set-option -gu $debug_flash_loop_nonce_opt >/dev/null 2>&1 || true

    local prev_counter
    prev_counter="$(tmux show-option -gqv "$debug_update_counter_opt" 2>/dev/null || true)"
    if [[ -n "${prev_counter:-}" && "${prev_counter:-}" != "0" ]]; then
      tmux set-option -gq "$debug_update_counter_opt" 0 >/dev/null 2>&1 || true
    fi

    return 0
  fi

  local existing
  existing="$(tmux show-option -gqv $debug_flash_loop_nonce_opt 2>/dev/null || true)"
  [[ -n "${existing:-}" ]] && return 0

  local nonce
  nonce="$(date +%s%N 2>/dev/null || date +%s)"

  tmux set-option -gq $debug_flash_loop_nonce_opt "$nonce" >/dev/null 2>&1 || true
  log_debug "flash-loop: start nonce=${nonce} period=${STALE_AFTER_SECONDS}"

  schedule_debug_flash_tick "$nonce" "$STALE_AFTER_SECONDS"
}

debug_flash_tick() {
  local expected_nonce="${1:-}"

  command -v tmux >/dev/null 2>&1 || return 0
  [[ -n "${expected_nonce:-}" ]] || return 0

  local current
  current="$(tmux show-option -gqv $debug_flash_loop_nonce_opt 2>/dev/null || true)"
  [[ -n "${current:-}" && "$current" == "$expected_nonce" ]] || return 0

  if ! debug_flash_loop_enabled; then
    tmux set-option -gu $debug_flash_loop_nonce_opt >/dev/null 2>&1 || true
    log_debug "flash-loop: stop"
    return 0
  fi

  debug_flash_codex_icons
  schedule_debug_flash_tick "$expected_nonce" "$STALE_AFTER_SECONDS"
}

LOCK_STALE_SECONDS=120

usage() {
  printf '%s\n' "Usage: $0 {session|weekly|--refresh|--debug-flash-tick <nonce>}" >&2
}

now_epoch() {
  date +%s
}

# Backoff state to avoid spawning refresh every status tick when
# remote refresh keeps failing (battery/network friendly).
# Format: "fail_count next_allowed_epoch" (plain text, no jq required).
read_refresh_backoff() {
  local fail_count next_allowed

  if [[ -f "$BACKOFF_FILE" ]]; then
    read -r fail_count next_allowed <"$BACKOFF_FILE" 2>/dev/null || true
  fi

  if [[ -z "${fail_count:-}" || ! "$fail_count" =~ ^[0-9]+$ ]]; then
    fail_count=0
  fi
  if [[ -z "${next_allowed:-}" || ! "$next_allowed" =~ ^[0-9]+$ ]]; then
    next_allowed=0
  fi

  printf '%s %s\n' "$fail_count" "$next_allowed"
}

refresh_backoff_delay_seconds() {
  local fail_count="${1:-0}"
  if [[ -z "${fail_count:-}" || ! "$fail_count" =~ ^[0-9]+$ ]]; then
    fail_count=0
  fi

  if (( fail_count <= 1 )); then
    printf '%s' 60
  elif (( fail_count == 2 )); then
    printf '%s' 120
  else
    printf '%s' 300
  fi
}

reset_refresh_backoff() {
  rm -f "$BACKOFF_FILE" 2>/dev/null || true
}

record_refresh_backoff_failure() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || true

  local fail_count next_allowed now delay
  read -r fail_count next_allowed < <(read_refresh_backoff)

  fail_count=$(( fail_count + 1 ))
  delay="$(refresh_backoff_delay_seconds "$fail_count")"
  now="$(now_epoch)"
  next_allowed=$(( now + delay ))

  umask 077
  printf '%s %s\n' "$fail_count" "$next_allowed" >"$BACKOFF_FILE" 2>/dev/null || true
}

refresh_fail() {
  record_refresh_backoff_failure
  return 1
}

iso_utc_to_epoch() {
  local iso="${1:-}"
  [[ -n "$iso" ]] || return 1

  local epoch
  epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || true)"
  if [[ -z "${epoch:-}" ]]; then
    if date -u -d "$iso" +%s >/dev/null 2>&1; then
      epoch="$(date -u -d "$iso" +%s 2>/dev/null || true)"
    fi
  fi

  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$epoch"
}

clamp_0_100_int() {
  local raw="$1" int

  if [[ "$raw" == *.* ]]; then
    int="${raw%%.*}"
  else
    int="$raw"
  fi

  if ! [[ "$int" =~ ^-?[0-9]+$ ]]; then
    return 1
  fi

  if (( int < 0 )); then
    int=0
  elif (( int > 100 )); then
    int=100
  fi

  printf '%s' "$int"
}

color_for_used_percent() {
  local used="$1"
  if (( used <= 49 )); then
    printf '%s' 'green'
  elif (( used <= 79 )); then
    printf '%s' 'yellow'
  else
    printf '%s' 'red'
  fi
}

weekly_pace_suffix() {
  local actual_used_percent="$1" window_minutes="$2" resets_at="$3" now="$4"

  [[ "$actual_used_percent" =~ ^[0-9]+$ ]] || return 0
  [[ "$window_minutes" =~ ^[0-9]+$ ]] || return 0
  [[ "$resets_at" =~ ^[0-9]+$ ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || return 0

  local duration time_until_reset elapsed
  duration=$(( window_minutes * 60 ))
  (( duration > 0 )) || return 0

  time_until_reset=$(( resets_at - now ))

  (( time_until_reset > 0 )) || return 0

  if (( time_until_reset > duration )); then
    return 0
  fi

  elapsed=$(( duration - time_until_reset ))
  if (( elapsed < 0 )); then
    elapsed=0
  elif (( elapsed > duration )); then
    elapsed=$duration
  fi

  if (( elapsed == 0 && actual_used_percent > 0 )); then
    return 0
  fi

  local expected_used delta_sign delta_abs
  expected_used="$(awk -v e="$elapsed" -v d="$duration" 'BEGIN { if (d <= 0) { print "0"; exit } printf "%.6f", (e / d) * 100 }')"


  read -r delta_sign delta_abs < <(
    awk -v a="$actual_used_percent" -v e="$expected_used" 'BEGIN {
      d = a - e
      if (d < 0) { sign = "-"; d = -d } else { sign = "+" }
      printf "%s %d", sign, int(d + 0.5)
    }'
  )

  printf ' (%s%s%%)' "$delta_sign" "$delta_abs"
}

read_cached_field() {
  local field="$1"

  [[ -f "$CACHE_FILE" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  jq -er ".$field" "$CACHE_FILE" 2>/dev/null
}

maybe_set_tmux_color_from_cache() {
  local mode="$1" field opt color

  [[ -f "$CACHE_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v tmux >/dev/null 2>&1 || return 0

  case "$mode" in
    session)
      field='session_color'
      opt='@codex_session_color'
      ;;
    weekly)
      field='weekly_color'
      opt='@codex_weekly_color'
      ;;
    *)
      return 0
      ;;
  esac

  color="$(jq -er ".$field" "$CACHE_FILE" 2>/dev/null || true)"
  [[ -n "${color:-}" ]] || return 0

  tmux set-option -gq "$opt" "$color" >/dev/null 2>&1 || true
}

cache_updated_at() {
  local ts
  ts="$(read_cached_field 'updated_at' || true)"
  if [[ -z "${ts:-}" || ! "$ts" =~ ^[0-9]+$ ]]; then
    printf '%s' 0
    return 0
  fi
  printf '%s' "$ts"
}

strip_legacy_label_prefix() {
  local v="${1:-}"

  v="${v#S:}"
  v="${v#W:}"

  if [[ "$v" == "--" ]]; then
    v="--%"
  fi

  printf '%s' "$v"
}

tmux_view_mode() {
  if ! command -v tmux >/dev/null 2>&1; then
    printf '%s' 'percent'
    return 0
  fi

  local v
  v="$(tmux show-option -gqv @codexbar_view 2>/dev/null || true)"
  case "${v:-}" in
    percent|reset)
      printf '%s' "$v"
      ;;
    *)
      printf '%s' 'percent'
      ;;
  esac
}

effective_view_for_mode() {
  local mode="${1:-}"

  local baseline
  baseline="$(tmux_view_mode)"

  command -v tmux >/dev/null 2>&1 || { printf '%s' "$baseline"; return 0; }

  local raw_until until now
  raw_until="$(tmux_opt_or_empty '@codexbar_reset_preview_until')"
  until="$(parse_int_with_default "$raw_until" 0)"
  now="$(now_epoch)"

  local preview_active=0
  if (( until == -1 || until > now )); then
    preview_active=1
  fi

  (( preview_active == 1 )) || { printf '%s' "$baseline"; return 0; }

  local scope
  scope="$(tmux_opt_or_empty '@codexbar_reset_view_scope')"
  case "${scope:-}" in
    session|weekly|both)
      :
      ;;
    *)
      scope='both'
      ;;
  esac

  case "$scope" in
    both)
      printf '%s' 'reset'
      ;;
    session)
      if [[ "$mode" == 'session' ]]; then
        printf '%s' 'reset'
      else
        printf '%s' "$baseline"
      fi
      ;;
    weekly)
      if [[ "$mode" == 'weekly' ]]; then
        printf '%s' 'reset'
      else
        printf '%s' "$baseline"
      fi
      ;;
  esac
}

format_time_until_reset() {
  local resets_at_epoch="$1" now="$2"

  if [[ -z "${resets_at_epoch:-}" || ! "$resets_at_epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' '--'
    return 0
  fi

  local delta_seconds
  delta_seconds=$(( resets_at_epoch - now ))
  if (( delta_seconds <= 0 )); then
    printf '%s' '--'
    return 0
  fi

  local total_minutes days hours minutes
  total_minutes=$(( delta_seconds / 60 ))
  if (( total_minutes <= 0 )); then
    printf '%s' '--'
    return 0
  fi

  days=$(( total_minutes / (60 * 24) ))
  hours=$(( (total_minutes / 60) % 24 ))
  minutes=$(( total_minutes % 60 ))

  if (( days >= 1 )); then
    printf '%sd%sh' "$days" "$hours"
  elif (( hours >= 1 )); then
    printf '%sh%sm' "$hours" "$minutes"
  else
    printf '%sm' "$minutes"
  fi
}

print_value() {
  local mode="$1" v view now resets_at

  view="$(effective_view_for_mode "$mode")"

  maybe_set_tmux_color_from_cache "$mode"

  local debug_suffix=''
  if (( CODEXBAR_USAGE_DEBUG != 0 )) && command -v tmux >/dev/null 2>&1; then
    local c
    c="$(tmux show-option -gqv "$debug_update_counter_opt" 2>/dev/null || true)"
    if ! [[ "${c:-}" =~ ^[0-9]+$ ]]; then
      c=0
    fi
    debug_suffix=" d${c}"
  fi

  if [[ "$view" == "reset" ]]; then
    now="$(now_epoch)"
    case "$mode" in
      session)
        resets_at="$(read_cached_field 'session_resets_at' 2>/dev/null || true)"
        ;;
      weekly)
        resets_at="$(read_cached_field 'weekly_resets_at' 2>/dev/null || true)"
        ;;
      *)
        usage
        exit 2
        ;;
    esac

    printf '%s\n' "$(format_time_until_reset "$resets_at" "$now")${debug_suffix}"
    return 0
  fi

  case "$mode" in
    session)
      v="$(read_cached_field 'session_text' 2>/dev/null || true)"
      if [[ -z "${v:-}" ]]; then
        printf '%s\n' "--%${debug_suffix}"
      else
        printf '%s\n' "$(strip_legacy_label_prefix "$v")${debug_suffix}"
      fi
      ;;
    weekly)
      v="$(read_cached_field 'weekly_text' 2>/dev/null || true)"
      if [[ -z "${v:-}" ]]; then
        printf '%s\n' "--%${debug_suffix}"
      else
        printf '%s\n' "$(strip_legacy_label_prefix "$v")${debug_suffix}"
      fi
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

lockdir_mtime_epoch() {
  local path="${1:-}"
  [[ -n "${path:-}" ]] || return 1

  local mtime
  mtime="$(stat -f %m "$path" 2>/dev/null || true)"
  if [[ "${mtime:-}" =~ ^[0-9]+$ ]]; then
    printf '%s' "$mtime"
    return 0
  fi

  mtime="$(stat -c %Y "$path" 2>/dev/null || true)"
  [[ "${mtime:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$mtime"
}

clear_stale_lock_if_needed() {
  [[ -d "$LOCKDIR" ]] || return 0

  local started_at now age
  if [[ -f "$LOCKDIR/started_at" ]]; then
    started_at="$(cat "$LOCKDIR/started_at" 2>/dev/null || true)"
  else
    now="$(now_epoch)"
    local mtime
    mtime="$(lockdir_mtime_epoch "$LOCKDIR" 2>/dev/null || true)"
    if [[ "${mtime:-}" =~ ^[0-9]+$ ]]; then
      age=$(( now - mtime ))
      if (( age > 2 )); then
        rm -rf "$LOCKDIR" 2>/dev/null || true
      fi
    fi
    return 0
  fi

  now="$(now_epoch)"
  if [[ "$started_at" =~ ^[0-9]+$ ]]; then
    age=$(( now - started_at ))
  else
    rm -rf "$LOCKDIR" 2>/dev/null || true
    return 0
  fi

  if (( age > LOCK_STALE_SECONDS )); then
    rm -rf "$LOCKDIR" 2>/dev/null || true
  fi
}

try_acquire_lock() {
  clear_stale_lock_if_needed

  if mkdir "$LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$(now_epoch)" >"$LOCKDIR/started_at" 2>/dev/null || { rm -rf "$LOCKDIR" 2>/dev/null || true; return 1; }
    printf '%s\n' "$$" >"$LOCKDIR/pid" 2>/dev/null || { rm -rf "$LOCKDIR" 2>/dev/null || true; return 1; }
    return 0
  fi

  clear_stale_lock_if_needed
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  printf '%s\n' "$(now_epoch)" >"$LOCKDIR/started_at" 2>/dev/null || { rm -rf "$LOCKDIR" 2>/dev/null || true; return 1; }
  printf '%s\n' "$$" >"$LOCKDIR/pid" 2>/dev/null || { rm -rf "$LOCKDIR" 2>/dev/null || true; return 1; }
  return 0
}

release_lock() {
  rm -rf "$LOCKDIR" 2>/dev/null || true
}

spawn_background_refresh_locked() {
  local script="$0"
  if [[ "$script" != /* ]]; then
    script="$(cd -- "$(dirname -- "$script")" && pwd)/$(basename -- "$script")"
  fi

  if ! try_acquire_lock; then
    log_debug "spawn: skip (lock busy)"
    return 0
  fi

  if command -v tmux >/dev/null 2>&1; then
    log_debug "spawn: tmux run-shell -b"
    if tmux run-shell -b "CODEXBAR_USAGE_LOCK_HELD=1 CODEXBAR_USAGE_LOCKDIR=\"$LOCKDIR\" \"$script\" --refresh >/dev/null 2>&1" >/dev/null 2>&1; then
      log_debug "spawn: tmux ok"
      return 0
    fi

    log_debug "spawn: tmux failed"
    release_lock
    return 1
  fi

  log_debug "spawn: nohup"
  nohup env CODEXBAR_USAGE_LOCK_HELD=1 CODEXBAR_USAGE_LOCKDIR="$LOCKDIR" "$script" --refresh >/dev/null 2>&1 &
  local nohup_status=$?
  if (( nohup_status == 0 )); then
    log_debug "spawn: nohup ok"
    return 0
  fi

  log_debug "spawn: nohup failed status=${nohup_status}"
  release_lock
  return 1
}

ensure_codex_cli_in_path() {
  command -v codex >/dev/null 2>&1 && return 0

  local bin

  local had_nullglob=0
  if shopt -q nullglob; then
    had_nullglob=1
  fi
  shopt -s nullglob
  local candidate
  for candidate in "$HOME/.nvm/versions/node/"*/bin/codex; do
    if [[ -x "$candidate" ]]; then
      bin="${candidate%/codex}"
      PATH="$bin:$PATH"
      export PATH
      break
    fi
  done
  if (( had_nullglob == 0 )); then
    shopt -u nullglob
  fi

  command -v codex >/dev/null 2>&1 && return 0

  if [[ -x "$HOME/.bun/bin/codex" ]]; then
    PATH="$HOME/.bun/bin:$PATH"
    export PATH
    return 0
  fi

  if [[ -x "$HOME/.local/bin/codex" ]]; then
    PATH="$HOME/.local/bin:$PATH"
    export PATH
    return 0
  fi

  return 0
}

refresh_cache() {
  mkdir -p "$CACHE_DIR"
  log_debug "refresh: start"

  if [[ "${CODEXBAR_USAGE_LOCK_HELD:-}" == "1" && "${CODEXBAR_USAGE_LOCKDIR:-}" == "$LOCKDIR" ]]; then
    log_debug "refresh: lock inherited"
  else
    if ! try_acquire_lock; then
      log_debug "refresh: lock busy"
      return 0
    fi
    log_debug "refresh: lock acquired"
  fi
  trap 'release_lock' EXIT

  if ! command -v codexbar >/dev/null 2>&1; then
    log_debug "refresh: missing tool codexbar"
    refresh_fail
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_debug "refresh: missing tool jq"
    refresh_fail
    return 1
  fi

  ensure_codex_cli_in_path

  local raw_json fetch_out fetch_err stderr_file

  stderr_file="$(mktemp "${CACHE_DIR}/codexbar.stderr.XXXXXX")"

  set +e
  fetch_out="$(codexbar --provider claude --format json --json-only --web-timeout "$WEB_TIMEOUT_SECONDS" 2>"$stderr_file")"
  local fetch_status=$?
  set -e
  fetch_err="$(cat "$stderr_file" 2>/dev/null || true)"

  if (( fetch_status != 0 )); then
    if [[ "$fetch_out" == *"Unknown option --json-only"* || "$fetch_err" == *"Unknown option --json-only"* ]]; then
      : >"$stderr_file" 2>/dev/null || true
      set +e
      fetch_out="$(codexbar --provider claude --format json --web-timeout "$WEB_TIMEOUT_SECONDS" 2>"$stderr_file")"
      fetch_status=$?
      set -e
      fetch_err="$(cat "$stderr_file" 2>/dev/null || true)"
    fi
  fi

  rm -f "$stderr_file" 2>/dev/null || true

  if (( fetch_status != 0 )); then
    log_debug_trunc "refresh: codexbar nonzero status=${fetch_status} err=${fetch_err} out=${fetch_out}" 300
    refresh_fail
    return 1
  fi

  raw_json="$fetch_out"

  local normalized session_raw weekly_raw
  if ! normalized="$(printf '%s' "$raw_json" | jq -ser '[.[] | (if type=="array" then .[0] else . end)] | map(select(.usage?)) | .[0]' 2>/dev/null)"; then
    log_debug_trunc "refresh: jq parse failure (normalize) out=${raw_json}" 300
    refresh_fail
    return 1
  fi

  if ! session_raw="$(printf '%s' "$normalized" | jq -er '.usage.primary.usedPercent | tonumber' 2>/dev/null)"; then
    log_debug "refresh: jq parse failure (session usedPercent)"
    refresh_fail
    return 1
  fi
  if ! weekly_raw="$(printf '%s' "$normalized" | jq -er '.usage.secondary.usedPercent | tonumber' 2>/dev/null)"; then
    log_debug "refresh: jq parse failure (weekly usedPercent)"
    refresh_fail
    return 1
  fi

  local session_window_minutes session_resets_at
  session_window_minutes="$(printf '%s' "$normalized" | jq -er '.usage.primary.windowMinutes // empty | tonumber' 2>/dev/null || true)"
  local session_resets_at_iso
  session_resets_at_iso="$(printf '%s' "$normalized" | jq -er -r '.usage.primary.resetsAt // empty | tostring' 2>/dev/null || true)"
  session_resets_at=""
  if [[ -n "${session_resets_at_iso:-}" ]]; then
    session_resets_at="$(iso_utc_to_epoch "$session_resets_at_iso" 2>/dev/null || true)"
  fi

  local weekly_window_minutes weekly_resets_at
  weekly_window_minutes="$(printf '%s' "$normalized" | jq -er '.usage.secondary.windowMinutes // empty | tonumber' 2>/dev/null || true)"
  local weekly_resets_at_iso
  weekly_resets_at_iso="$(printf '%s' "$normalized" | jq -er -r '.usage.secondary.resetsAt // empty | tostring' 2>/dev/null || true)"
  weekly_resets_at=""
  if [[ -n "${weekly_resets_at_iso:-}" ]]; then
    weekly_resets_at="$(iso_utc_to_epoch "$weekly_resets_at_iso" 2>/dev/null || true)"
  fi

  local session_window_minutes_json session_resets_at_json weekly_window_minutes_json weekly_resets_at_json
  session_window_minutes_json='null'
  session_resets_at_json='null'
  weekly_window_minutes_json='null'
  weekly_resets_at_json='null'

  if [[ "$session_window_minutes" =~ ^[0-9]+$ ]]; then
    session_window_minutes_json="$session_window_minutes"
  fi
  if [[ "$session_resets_at" =~ ^[0-9]+$ ]]; then
    session_resets_at_json="$session_resets_at"
  fi
  if [[ "$weekly_window_minutes" =~ ^[0-9]+$ ]]; then
    weekly_window_minutes_json="$weekly_window_minutes"
  fi
  if [[ "$weekly_resets_at" =~ ^[0-9]+$ ]]; then
    weekly_resets_at_json="$weekly_resets_at"
  fi

  local session_used weekly_used
  session_used="$(clamp_0_100_int "$session_raw")" || { refresh_fail; return 1; }
  weekly_used="$(clamp_0_100_int "$weekly_raw")" || { refresh_fail; return 1; }

  local updated_at
  updated_at="$(now_epoch)"

  local weekly_pace
  weekly_pace="$(weekly_pace_suffix "$weekly_used" "$weekly_window_minutes" "$weekly_resets_at" "$updated_at")"

  local session_text weekly_text session_color weekly_color
  session_text="${session_used}%"
  weekly_text="${weekly_used}%${weekly_pace}"
  session_color="$(color_for_used_percent "$session_used")"
  weekly_color="$(color_for_used_percent "$weekly_used")"

  local tmp
  tmp="$(mktemp "${CACHE_DIR}/usage.json.tmp.XXXXXX")"

  umask 077
  cat >"$tmp" <<EOF
{"updated_at":${updated_at},"session_used":${session_used},"weekly_used":${weekly_used},"session_window_minutes":${session_window_minutes_json},"session_resets_at":${session_resets_at_json},"weekly_window_minutes":${weekly_window_minutes_json},"weekly_resets_at":${weekly_resets_at_json},"session_windowMinutes":${session_window_minutes_json},"session_resetsAt":${session_resets_at_json},"weekly_windowMinutes":${weekly_window_minutes_json},"weekly_resetsAt":${weekly_resets_at_json},"session_text":"${session_text}","weekly_text":"${weekly_text}","session_color":"${session_color}","weekly_color":"${weekly_color}"}
EOF

  mv -f "$tmp" "$CACHE_FILE"

  if command -v tmux >/dev/null 2>&1; then
    tmux set-option -gq @codex_session_color "$session_color" >/dev/null 2>&1 || true
    tmux set-option -gq @codex_weekly_color "$weekly_color" >/dev/null 2>&1 || true

    local debug_opt
    debug_opt="$(tmux show-option -gqv @codexbar_debug 2>/dev/null || true)"

    if [[ "${debug_opt:-}" =~ ^[0-9]+$ ]] && (( debug_opt != 0 )); then
      local n
      n="$(tmux show-option -gqv "$debug_update_counter_opt" 2>/dev/null || true)"
      if ! [[ "${n:-}" =~ ^[0-9]+$ ]]; then
        n=0
      fi
      n=$(( n + 1 ))
      tmux set-option -gq "$debug_update_counter_opt" "$n" >/dev/null 2>&1 || true
    else
      tmux set-option -gq "$debug_update_counter_opt" 0 >/dev/null 2>&1 || true
    fi

    tmux refresh-client -S >/dev/null 2>&1 || true
  fi

  log_debug "refresh: success updated_at=${updated_at} session=${session_used}% weekly=${weekly_used}%"

  reset_refresh_backoff
}

main() {
  local mode="${1:-}"

  case "$mode" in
    --refresh)
      refresh_cache || true
      exit 0
      ;;
    --debug-flash-tick)
      debug_flash_tick "${2:-}"
      exit 0
      ;;
    session|weekly)
      :
      ;;
    *)
      usage
      exit 2
      ;;
  esac

  start_debug_flash_loop_if_needed

  print_value "$mode"

  local ts now age
  ts="$(cache_updated_at)"
  now="$(now_epoch)"
  age=$(( now - ts ))

  if [[ ! -f "$CACHE_FILE" ]] || (( age >= STALE_AFTER_SECONDS )); then
    mkdir -p "$CACHE_DIR"

    log_debug "stale: now=${now} ts=${ts} age=${age} threshold=${STALE_AFTER_SECONDS}"

    local fail_count next_allowed
    read -r fail_count next_allowed < <(read_refresh_backoff)
    if (( now < next_allowed )); then
      log_debug "stale: backoff fail_count=${fail_count} next_allowed=${next_allowed}"
      return 0
    fi

    log_debug "stale: spawn refresh"
    spawn_background_refresh_locked || true
  fi
}

main "$@"
