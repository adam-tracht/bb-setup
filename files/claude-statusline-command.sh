#!/usr/bin/env bash
# Claude Code status line: tokens in context + session + weekly rate limits

input=$(cat)

# Active tokens in context window
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Rate limits: percentages and reset timestamps (Unix epoch seconds)
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_resets_at=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

parts=()

# Tokens: show used count and % of window
if [ -n "$total_input" ] && [ -n "$ctx_size" ]; then
  if [ -n "$used_pct" ]; then
    parts+=("$(printf 'ctx: %sk / %sk (%.0f%%)' "$((total_input / 1000))" "$((ctx_size / 1000))" "$used_pct")")
  else
    parts+=("$(printf 'ctx: %sk / %sk' "$((total_input / 1000))" "$((ctx_size / 1000))")")
  fi
fi

# Session limit (5h) with reset clock time in local time
if [ -n "$five_pct" ]; then
  if [ -n "$five_resets_at" ]; then
    reset_time=$(date -r "$five_resets_at" "+%-I:%M%p" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    parts+=("$(printf '5h: %.0f%% (resets %s)' "$five_pct" "$reset_time")")
  else
    parts+=("$(printf '5h: %.0f%%' "$five_pct")")
  fi
fi

# Weekly limit (7d) with reset weekday (+ time if it fits)
if [ -n "$week_pct" ]; then
  if [ -n "$week_resets_at" ]; then
    reset_day=$(date -r "$week_resets_at" "+%a" 2>/dev/null)
    reset_time=$(date -r "$week_resets_at" "+%-I:%M%p" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    parts+=("$(printf '7d: %.0f%% (resets %s %s)' "$week_pct" "$reset_day" "$reset_time")")
  else
    parts+=("$(printf '7d: %.0f%%' "$week_pct")")
  fi
fi

if [ ${#parts[@]} -gt 0 ]; then
  printf '%s' "$(IFS=' | '; echo "${parts[*]}")"
fi
