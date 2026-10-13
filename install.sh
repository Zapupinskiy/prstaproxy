#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Запусти команду через sudo bash.' >&2; exit 1; }
[[ -r /etc/os-release ]] || exit 1
source /etc/os-release
[[ "$ID" == ubuntu || "$ID" == debian ]] || { echo 'Поддерживаются Ubuntu и Debian'; exit 1; }
export DEBIAN_FRONTEND=noninteractive
log=/var/log/prostoweb-bootstrap.log
touch "$log"; chmod 600 "$log"
bootstrap_stage(){
 local title=$1; shift
 local pid start=$SECONDS frame=0 chars='|/-\' rc=0
 "$@" >> "$log" 2>&1 & pid=$!
 while kill -0 "$pid" 2>/dev/null; do
  printf '\r  %s %s · %02d:%02d' "${chars:frame%4:1}" "$title" "$(((SECONDS-start)/60))" "$(((SECONDS-start)%60))"
  frame=$((frame+1)); sleep 0.2
 done
 wait "$pid" || rc=$?
 printf '\r  %s %s · %02d:%02d\n' "$([[ $rc == 0 ]] && echo '✓' || echo '✗')" "$title" "$(((SECONDS-start)/60))" "$(((SECONDS-start)%60))"
 if ((rc)); then tail -n 20 "$log" >&2; return "$rc"; fi
}
echo 'Подготовка установщика'
bootstrap_stage 'Обновление списка пакетов' apt-get update
bootstrap_stage 'Зависимости загрузчика' apt-get install -y --no-install-recommends git curl ca-certificates
base=/opt/prostoweb
mkdir -p "$base/app/releases"
tmp=$(mktemp -d "$base/app/releases/download.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
bootstrap_stage 'Загрузка проекта GitHub' git clone --depth 1 https://github.com/Zapupinskiy/prstaproxy.git "$tmp"
for file in prstaproxy.sh lib/core.sh lib/selfsteal.sh vendor/selfsteal.sh; do bash -n "$tmp/$file"; done
release="$base/app/releases/$(git -C "$tmp" rev-parse HEAD)"
if [[ ! -d "$release" ]]; then mv "$tmp" "$release"; fi
ln -sfn "$release" "$base/app/current.new"
mv -Tf "$base/app/current.new" "$base/app/current"
bash "$release/prstaproxy.sh" --install-menu
exec bash "$release/prstaproxy.sh" --install
