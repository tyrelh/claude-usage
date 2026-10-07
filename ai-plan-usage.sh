#!/usr/bin/env bash
set -euo pipefail

KEYCHAIN_SERVICE='Claude Code-credentials'
CODEX_AUTH="${CODEX_HOME:-$HOME/.codex}/auth.json"
REFRESH_BUFFER_SECONDS=60
FULL_OUTPUT=false
INTERVAL=600  # seconds between refreshes
BAR_WIDTH=auto
MIN_BAR=10
FALLBACK_BAR=30
PROVIDERS=(claude codex)

# Parse flags
for arg in "$@"; do
  case $arg in
    --full) FULL_OUTPUT=true ;;
    --interval=*) INTERVAL="${arg#--interval=}" ;;
    --width=*) BAR_WIDTH="${arg#--width=}" ;;
    --providers=*) IFS=, read -r -a PROVIDERS <<<"${arg#--providers=}" ;;
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
  # Sets global COMPUTED_WIDTH. Arg1 = reset string length, Arg2 = label width.
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
  # Overhead: "LABEL [] 100%  (resets <reset>)" = label_w + 19 + reset_len
  local reset_len=${1:-10}
  local overhead=$(( ${2:-8} + 19 + reset_len ))
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
  local label_w=$6

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

  printf "%-*s %s[%s]%s %3d%%  (resets %-*s)\n" \
    "$label_w" "$label" "$color" "$bar" "$reset_color" "$pct" "$reset_pad" "$reset"
}

# GETs $1 with request headers read from stdin, so tokens stay out of argv.
# Prints the body; on non-200 prints the status and body to stderr and fails.
http_get() {
  local body meta code retry_after
  body=$(mktemp)
  meta=$(curl -sS -o "$body" -w '%{http_code} %header{retry-after}' -H @- "$1") || { rm -f "$body"; return 1; }
  code=${meta%% *}
  retry_after=${meta#* }
  if [[ "$code" != "200" ]]; then
    echo "HTTP $code${retry_after:+ (retry-after ${retry_after}s)}: $(cat "$body")" >&2
    rm -f "$body"
    return 1
  fi
  cat "$body"
  rm -f "$body"
}

# Shared jq helpers. fmt_reset takes an ISO-8601 string or epoch seconds.
JQ_DEFS='
  def fmt_reset(t):
    if t == null then "unknown"
    else
      ((if (t | type) == "number" then t
        else t | sub("\\.[0-9]+"; "") | sub("\\+00:00"; "Z") | fromdateiso8601 end) - now) as $d
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
'

# Providers: each <name> in PROVIDERS needs two functions.
#   fetch_<name>  prints the raw JSON response; on failure explains on stderr and returns non-zero
#   rows_<name>   reads that JSON on stdin and prints "label<TAB>percent<TAB>reset" rows (none = unexpected shape)

fetch_claude() {
  if is_expired; then
    refresh_token
    if is_expired; then
      # ponytail: dead refresh token can't be fixed here — API 429s expired tokens (~1h retry-after), so don't feed the throttle
      echo "OAuth token expired and refresh failed. Run 'claude' in a terminal and '/login', then restart this script." >&2
      return 1
    fi
  fi

  local token
  token=$(read_keychain | jq -r '.claudeAiOauth.accessToken')
  printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\nAccept: application/json\nUser-Agent: claude-code/2.0.32\n' "$token" \
    | http_get https://api.anthropic.com/api/oauth/usage \
    || { echo "Note: this API returns 429, not 401, for expired tokens." >&2; return 1; }
}

rows_claude() {
  jq -r "$JQ_DEFS"'
    select(has("five_hour") and has("seven_day")) |
    "Claude 5-hour\t\((.five_hour.utilization // 0)|floor)\t\(fmt_reset(.five_hour.resets_at))",
    "Claude 7-day\t\((.seven_day.utilization // 0)|floor)\t\(fmt_reset(.seven_day.resets_at))",
    (if (.extra_usage.used_credits // 0) > 0 then
      "Claude extra\t\((.extra_usage.utilization // 0)|floor)\t\(.extra_usage.used_credits) \(.extra_usage.currency)" +
      (if .extra_usage.monthly_limit != null then
        " of \(.extra_usage.monthly_limit)"
      else "" end)
    else empty end)
  '
}

# ponytail: undocumented endpoint the Codex CLI itself polls; no token refresh here, running codex refreshes auth.json
fetch_codex() {
  if [[ ! -r "$CODEX_AUTH" ]]; then
    echo "No $CODEX_AUTH. Run 'codex login' (file-based credential store)." >&2
    return 1
  fi
  jq -r '"Authorization: Bearer \(.tokens.access_token)\nChatGPT-Account-Id: \(.tokens.account_id)\nAccept: application/json\nUser-Agent: codex-cli"' "$CODEX_AUTH" \
    | http_get https://chatgpt.com/backend-api/wham/usage \
    || { echo "On HTTP 401, run 'codex' once to refresh its login." >&2; return 1; }
}

rows_codex() {
  # Window lengths come from the API; OpenAI has toggled the 5-hour window before.
  jq -r "$JQ_DEFS"'
    def window_label(s): if s % 86400 == 0 then "\(s / 86400)-day" else "\(s / 3600 | floor)-hour" end;
    .rate_limit // empty | (.primary_window, .secondary_window) // empty |
    "Codex \(window_label(.limit_window_seconds))\t\(.used_percent | floor)\t\(fmt_reset(.reset_at))"
  '
}

for p in "${PROVIDERS[@]}"; do
  declare -F "fetch_$p" >/dev/null || { echo "Unknown provider: $p" >&2; exit 1; }
done

fetch_and_display() {
  local header_ts="Usage at $(date '+%H:%M:%S')"
  local rows=() errors="" full="" errf p json parsed line
  errf=$(mktemp)

  for p in "${PROVIDERS[@]}"; do
    if json=$("fetch_$p" 2>"$errf"); then
      if $FULL_OUTPUT; then
        full+="$p:"$'\n'"$(jq <<<"$json")"$'\n'
      else
        parsed=$("rows_$p" <<<"$json" 2>>"$errf" || true)
        if [[ -z "$parsed" ]]; then
          echo "Unexpected response shape:"$'\n'"$json" >>"$errf"
        fi
        while IFS= read -r line; do
          [[ -n "$line" ]] && rows+=("$line")
        done <<<"$parsed"
      fi
    fi
    [[ -s "$errf" ]] && errors+="$(sed "s/^/$p: /" "$errf")"$'\n'
  done
  rm -f "$errf"

  [[ -t 1 ]] && printf '\033[H\033[2J'

  if (( ${#rows[@]} == 0 )); then
    render_header "$header_ts" 0 "$(term_cols)"
  else
    # Pass 1: find max label and reset lengths.
    local label pct reset row max_label_len=0 max_reset_len=0
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r label pct reset <<<"$row"
      (( ${#label} > max_label_len )) && max_label_len=${#label}
      (( ${#reset} > max_reset_len )) && max_reset_len=${#reset}
    done

    # Pass 2: single bar width based on max lengths, render padded.
    compute_bar_width "$max_reset_len" "$max_label_len"
    local bar_w=$COMPUTED_WIDTH
    # Label area = label width + 1 space. [BAR] = bar_w + 2.
    render_header "$header_ts" $(( max_label_len + 1 )) $(( bar_w + 2 ))

    for row in "${rows[@]}"; do
      IFS=$'\t' read -r label pct reset <<<"$row"
      render_bar "$pct" "$label" "$reset" "$bar_w" "$max_reset_len" "$max_label_len"
    done
  fi

  [[ -n "$full" ]] && printf '%s' "$full"
  [[ -n "$errors" ]] && printf '%s' "$errors" >&2
  return 0
}

while true; do
  fetch_and_display
  sleep "$INTERVAL"
done
