#!/usr/bin/env bash
# Shared screen state is kept in the parent shell, never in background workers.
UI_HEADER=$'\033[34m'
UI_TITLE=$'\033[36m'
UI_LOADER=$'\033[35m'
UI_RESET=$'\033[0m'
declare -a UI_ANSWERS=() UI_HISTORY=()
UI_CURRENT=
terminal_clear(){ printf '\033[2J\033[H'; }
print_header(){
 local title=$1 padding
 padding=$((59-${#title})); ((padding>=0)) || padding=0
 printf '%s╔════════════════════════════════════════════════════════════╗\n' "$UI_HEADER"
 printf '║ %s%*s║\n' "$title" "$padding" ''
 printf '╚════════════════════════════════════════════════════════════╝%s\n' "$UI_RESET"
}
ui_status(){
 local state=$1 label=$2 color symbol
 case "$state" in
  success) color=$'\033[32m'; symbol='✓';;
  error) color=$'\033[31m'; symbol='✗';;
  warning) color=$'\033[33m'; symbol='!';;
  skipped) color=$'\033[90m'; symbol='−';;
  *) color=$UI_LOADER; symbol='…';;
 esac
 printf '%s%s %s%s\n' "$color" "$symbol" "$label" "$UI_RESET"
}
summary_add(){ UI_ANSWERS+=("$1: $2"); }
screen_begin(){
 terminal_clear
 print_header 'ПРОСТОВПН WEB PROXY'
 local row
 for row in "${UI_ANSWERS[@]}"; do printf '  %s\n' "$row"; done
 for row in "${UI_HISTORY[@]}"; do printf '  %s\n' "$row"; done
 UI_FINISHED=0
 UI_CURRENT="ЭТАП $1. $2"
 printf '\n%s%s%s\n\n' "$UI_TITLE" "$UI_CURRENT" "$UI_RESET"
}
screen_finish(){
 UI_FINISHED=1
 local line
 printf -v line '%s' "$(ui_status "$1" "$UI_CURRENT")"
 UI_HISTORY+=("$line")
 printf '\n%s\n' "$line"
}
wizard_reset(){ UI_ANSWERS=(); UI_HISTORY=(); UI_CURRENT=; INSTALL_WIZARD=1; }
