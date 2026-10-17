#!/usr/bin/env bash
# Shared screen state is kept in the parent shell, never in background workers.
UI_HEADER=$'\033[34m'
UI_TITLE=$'\033[34m'
UI_LOADER=$'\033[34m'
UI_RESET=$'\033[0m'
declare -a UI_ANSWERS=() UI_HISTORY=() UI_HISTORY_IDS=()
UI_CURRENT=
UI_STAGE_ID=
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
 printf '%s%s%s %s\n' "$color" "$symbol" "$UI_RESET" "$label"
}
summary_add(){
 local index
 for ((index=0;index<${#UI_ANSWERS[@]};index++)); do
  if [[ "${UI_ANSWERS[index]}" == "$1: "* ]]; then UI_ANSWERS[index]="$1: $2"; return 0; fi
 done
 UI_ANSWERS+=("$1: $2")
}
screen_begin(){
 terminal_clear
 print_header 'ПРОСТОВПН WEB PROXY'
 local row separator=''
 for row in "${UI_ANSWERS[@]}"; do
  case "$row" in
   'Домен: '*|'Режим: '*|'SelfSteal: '*) printf '%s%s' "$separator" "$row"; separator=' · ';;
  esac
 done
 [[ -z "$separator" ]] || printf '\n'
 if ((${#UI_HISTORY[@]})); then printf '%s  ' "${UI_HISTORY[@]}"; printf '\n'; fi
 UI_FINISHED=0
 UI_STAGE_ID=$1
 UI_CURRENT="ЭТАП $1. $2"
 printf '\n%s%s%s\n\n' "$UI_TITLE" "$UI_CURRENT" "$UI_RESET"
}
screen_finish(){
 UI_FINISHED=1
 local line index found=0
 line=$(ui_status "$1" "$UI_STAGE_ID")
 for ((index=0;index<${#UI_HISTORY_IDS[@]};index++)); do
  if [[ "${UI_HISTORY_IDS[index]}" == "$UI_STAGE_ID" ]]; then UI_HISTORY[index]=$line; found=1; break; fi
 done
 if ((found==0)); then UI_HISTORY_IDS+=("$UI_STAGE_ID"); UI_HISTORY+=("$line"); fi
 printf '\n'; ui_status "$1" "$UI_CURRENT"
}
wizard_reset(){ UI_ANSWERS=(); UI_HISTORY=(); UI_HISTORY_IDS=(); UI_CURRENT=; UI_STAGE_ID=; INSTALL_WIZARD=1; }
