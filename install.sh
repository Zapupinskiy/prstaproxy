#!/usr/bin/env bash
set -Eeuo pipefail
printf '\033[2J\033[H'
# Prompts must read the terminal when the installer is piped into bash.
[[ -r /dev/tty ]] || { echo 'Нужен интерактивный терминал.' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'Запусти команду через sudo bash.' >&2; exit 1; }
[[ -r /etc/os-release ]] || exit 1
source /etc/os-release
[[ "$ID" == ubuntu || "$ID" == debian ]] || { echo 'Поддерживаются Ubuntu и Debian'; exit 1; }
export DEBIAN_FRONTEND=noninteractive
log=/var/log/prostoweb-bootstrap.log
touch "$log"; chmod 600 "$log"
bootstrap_history=()
bootstrap_screen(){
 printf '\033[2J\033[H\033[34m╔════════════════════════════════════════════════════════════╗\n║ ПРОСТОВПН WEB PROXY — загрузчик\n╚════════════════════════════════════════════════════════════╝\033[0m\n'
 local item
 for item in "${bootstrap_history[@]}"; do printf '%s\n' "$item"; done
 printf '\n\033[36m%s\033[0m\n' "$1"
}
bootstrap_stage(){
 local title=$1; shift
 bootstrap_screen "$title"
 local pid start=$SECONDS frame=0 chars='|/-\' rc=0
 "$@" >> "$log" 2>&1 & pid=$!
 while kill -0 "$pid" 2>/dev/null; do
  printf '\r\033[35m  %s %s · %02d:%02d\033[0m' "${chars:frame%4:1}" "$title" "$(((SECONDS-start)/60))" "$(((SECONDS-start)%60))"
  frame=$((frame+1)); sleep 0.2
 done
 wait "$pid" || rc=$?
 local result color
 if ((rc)); then result='✗'; color=$'\033[31m'; else result='✓'; color=$'\033[32m'; fi
 printf '\r%s  %s %s · %02d:%02d\033[0m\n' "$color" "$result" "$title" "$(((SECONDS-start)/60))" "$(((SECONDS-start)%60))"
 bootstrap_history+=("$color$result $title"$'\033[0m')
 if ((rc)); then tail -n 20 "$log" >&2; return "$rc"; fi
}
bootstrap_screen 'Проверка зависимостей загрузчика'
missing=()
for package in git curl ca-certificates; do
 status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
 if [[ "$status" == 'install ok installed' ]]; then
  printf '\033[32m✓ %s уже установлен\033[0m\n' "$package"
 else missing+=("$package"); printf '\033[33m! %s отсутствует\033[0m\n' "$package"; fi
done
if ((${#missing[@]})); then
 bootstrap_stage 'Обновление списка пакетов' apt-get update
 bootstrap_stage 'Недостающие зависимости загрузчика' apt-get install -y --no-install-recommends "${missing[@]}"
else
 bootstrap_history+=($'\033[90m− Установка зависимостей загрузчика не требуется\033[0m')
fi
base=/opt/prostoweb
mkdir -p "$base/app/releases"
tmp=$(mktemp -d "$base/app/releases/download.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
bootstrap_stage 'Загрузка проекта GitHub' git clone --depth 1 https://github.com/Zapupinskiy/prstaproxy.git "$tmp"
for file in prstaproxy.sh lib/core.sh lib/interface.sh lib/ui.sh lib/selfsteal.sh vendor/selfsteal.sh; do bash -n "$tmp/$file"; done
release="$base/app/releases/$(git -C "$tmp" rev-parse HEAD)"
if [[ ! -d "$release" ]]; then mv "$tmp" "$release"; fi
ln -sfn "$release" "$base/app/current.new"
mv -Tf "$base/app/current.new" "$base/app/current"
bash "$release/prstaproxy.sh" --install-menu
exec bash "$release/prstaproxy.sh" --install
