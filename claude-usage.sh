#!/usr/bin/env bash
set -euo pipefail

KEYCHAIN_SERVICE='Claude Code-credentials'
REFRESH_BUFFER_SECONDS=60
FULL_OUTPUT=false
INTERVAL=600  # seconds between refreshes
BAR_WIDTH=auto
MIN_BAR=10
FALLBACK_BAR=30

# Parse flags
for arg in "$@"; do
  case $arg in
    --full) FULL_OUTPUT=true ;;
    --interval=*) INTERVAL="${arg#--interval=}" ;;
    --width=*) BAR_WIDTH="${arg#--width=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

read_keychain() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -w
}

is_expired() {
  local expiry_ms now_ms
  expiry_ms=$(read_keychain | jq -r '.claudeAiOauth.expiresAt')
  now_ms=$(($(date +%s) * 1000))
  (( expiry_ms - now_ms < REFRESH_BUFFER_SECONDS * 1000 ))
}

refresh_token() {
  echo "Token expired or near expiry; refreshing via claude CLI..." >&2
  local saved_stty
  saved_stty=$(stty -g </dev/tty 2>/dev/null || true)
  claude -p "ok" --model haiku </dev/null >/dev/null 2>&1 || {
    echo "Warning: claude refresh call failed; trying with current token anyway." >&2
  }
  [[ -n "$saved_stty" ]] && stty "$saved_stty" </dev/tty 2>/dev/null || true
}

term_cols() {
  local cols=0
  if [[ -r /dev/tty ]]; then
    local size
    size=$(stty size </dev/tty 2>/dev/null || true)
    cols=${size##* }
  fi
  if [[ -z "$cols" || "$cols" == "0" ]]; then
    cols=${COLUMNS:-80}
  fi
  echo "$cols"
}

render_header() {
  local ts="$1"
  local label_offset="$2"   # chars before '['
  local bar_region="$3"     # width of [BAR]

  local marker="◆"
  local gap="   "  # 3 spaces between marker and text
  # Content: "◆<gap><ts><gap>◆" = 1 + 3 + ts_len + 3 + 1 = ts_len + 8
  local content_len=$(( ${#ts} + 8 ))
  local inner_pad=$(( (bar_region - content_len) / 2 ))
  if (( inner_pad < 0 )); then inner_pad=0; fi
  local pad=$(( label_offset + inner_pad ))

  local bold=$'\033[1m'
  local reset=$'\033[0m'

  printf '%*s%s%s%s%s%s%s%s\n' \
    "$pad" "" \
    "$marker" "$gap" \
    "$bold" "$ts" "$reset" \
    "$gap" "$marker"
}

compute_bar_width() {
  # Sets global COMPUTED_WIDTH. Arg1 = reset string length.
  if [[ "$BAR_WIDTH" != "auto" ]]; then
    COMPUTED_WIDTH=$BAR_WIDTH
    return
  fi
  local cols
  cols=$(term_cols)
  if (( cols <= 0 )); then
    COMPUTED_WIDTH=$FALLBACK_BAR
    return
  fi
  # Overhead: "LABEL    [] 100%  (resets <reset>)" = 27 + reset_len
  local reset_len=${1:-10}
  local overhead=$(( 27 + reset_len ))
  local w=$(( cols - overhead ))
  if (( w < MIN_BAR )); then w=$MIN_BAR; fi
  COMPUTED_WIDTH=$w
}

render_bar() {
  local pct=$1
  local label=$2
  local reset=$3
  local width=$4
  local reset_pad=$5

  # Clamp 0..100
  if (( pct < 0 )); then pct=0; fi
  if (( pct > 100 )); then pct=100; fi

  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))

  local color reset_color
  reset_color=$'\033[0m'
  if (( pct <= 50 )); then
    color=$'\033[32m'  # green
  elif (( pct <= 75 )); then
    color=$'\033[33m'  # yellow
  else
    color=$'\033[31m'  # red
  fi

  local bar=""
  local i
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty; i++ )); do bar+="░"; done

  printf "%-8s %s[%s]%s %3d%%  (resets %-*s)\n" \
    "$label" "$color" "$bar" "$reset_color" "$pct" "$reset_pad" "$reset"
}

fetch_and_display() {
  if is_expired; then
    refresh_token
  fi

  [[ -t 1 ]] && printf '\033[H\033[2J'

  TOKEN=$(read_keychain | jq -r '.claudeAiOauth.accessToken')

  HTTP_CODE=$(curl -sS -o /tmp/claude-usage-body.$$ -w "%{http_code}" \
    https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Accept: application/json" \
    -H "User-Agent: claude-code/2.0.32")
  RESPONSE=$(cat /tmp/claude-usage-body.$$)
  rm -f /tmp/claude-usage-body.$$

  local header_ts="Claude usage at $(date '+%H:%M:%S')"

  if [[ "$HTTP_CODE" == "429" ]]; then
    local msg
    msg=$(echo "$RESPONSE" | jq -r '.error.message // "rate limited"' 2>/dev/null || echo "rate limited")
    render_header "$header_ts" 0 "$(term_cols)"
    echo "HTTP 429: $msg" >&2
    return
  fi

  if [[ "$HTTP_CODE" != "200" ]]; then
    render_header "$header_ts" 0 "$(term_cols)"
    echo "HTTP $HTTP_CODE:" >&2
    echo "$RESPONSE" >&2
    return
  fi

  if $FULL_OUTPUT; then
    render_header "$header_ts" 0 "$(term_cols)"
    echo "$RESPONSE" | jq
    return
  fi

  # Guard: if expected fields missing, dump raw response to aid debug.
  if ! echo "$RESPONSE" | jq -e 'has("five_hour") and has("seven_day")' >/dev/null 2>&1; then
    render_header "$header_ts" 0 "$(term_cols)"
    echo "Unexpected response shape:" >&2
    echo "$RESPONSE" >&2
    return
  fi

  # Parse fields with jq into a TSV; consume line by line.
  local parsed
  parsed=$(echo "$RESPONSE" | jq -r '
    def fmt_reset(t):
      if t == null then "unknown"
      else
        ((t | sub("\\.[0-9]+"; "") | sub("\\+00:00"; "Z") | fromdateiso8601) - now) as $d
        | if $d < 0 then "expired"
          else
            ($d/86400|floor) as $days |
            (($d%86400)/3600|floor) as $hrs |
            (($d%3600)/60|floor) as $min |
            if $days > 0 then "in \($days)d \($hrs)h"
            elif $hrs > 0 then "in \($hrs)h \($min)m"
            else "in \($min)m" end
          end
      end;

    "5-hour\t\((.five_hour.utilization // 0)|floor)\t\(fmt_reset(.five_hour.resets_at))",
    "7-day\t\((.seven_day.utilization // 0)|floor)\t\(fmt_reset(.seven_day.resets_at))",
    (if (.extra_usage.used_credits // 0) > 0 then
      "extra\t\((.extra_usage.utilization // 0)|floor)\t\(.extra_usage.used_credits) \(.extra_usage.currency)" +
      (if .extra_usage.monthly_limit != null then
        " of \(.extra_usage.monthly_limit)"
      else "" end)
    else empty end)
  ')

  # Pass 1: collect rows, find max reset length.
  local rows=()
  local max_reset_len=0
  while IFS=$'\t' read -r label pct reset; do
    [[ -z "$label" ]] && continue
    rows+=("$label"$'\t'"$pct"$'\t'"$reset")
    if (( ${#reset} > max_reset_len )); then
      max_reset_len=${#reset}
    fi
  done <<< "$parsed"

  # Pass 2: single bar width based on max reset, render padded.
  compute_bar_width "$max_reset_len"
  local bar_w=$COMPUTED_WIDTH
  # Label area "LABEL   " = %-8s + 1 space = 9 chars. [BAR] = bar_w + 2.
  render_header "$header_ts" 9 $(( bar_w + 2 ))

  local row
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r label pct reset <<<"$row"
    render_bar "$pct" "$label" "$reset" "$bar_w" "$max_reset_len"
  done
}

while true; do
  fetch_and_display
  sleep "$INTERVAL"
done
