#!/usr/bin/env bash

set -euo pipefail

target_client="${1:-}"
popup_session="btop-popup"
current_session="$(tmux display-message -p '#{session_name}')"

if [ "$current_session" = "$popup_session" ]; then
  tmux kill-session -t "$popup_session"
  exit 0
fi

if tmux has-session -t "$popup_session" 2>/dev/null; then
  popup_cmd="tmux attach-session -t $popup_session"
else
  popup_cmd="tmux new-session -s $popup_session btop"
fi

if [ -n "$target_client" ]; then
  tmux display-popup -t "$target_client" -E -w 85% -h 85% "$popup_cmd"
else
  tmux display-popup -E -w 85% -h 85% "$popup_cmd"
fi
