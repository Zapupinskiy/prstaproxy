#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p /data
refresh(){
 curl -fsSL --retry 3 --max-time 30 https://core.telegram.org/getProxySecret -o /data/proxy-secret.new
 curl -fsSL --retry 3 --max-time 30 https://core.telegram.org/getProxyConfig -o /data/proxy-multi.conf.new
 [[ $(wc -c < /data/proxy-secret.new) -eq 128 ]]
 grep -q '^proxy_for ' /data/proxy-multi.conf.new
 mv /data/proxy-secret.new /data/proxy-secret
 mv /data/proxy-multi.conf.new /data/proxy-multi.conf
}
if ! refresh; then
 [[ -s /data/proxy-secret && -s /data/proxy-multi.conf ]] || exit 1
fi
source /config/backend.env
local_ip=$(ip -4 route get 149.154.175.50 | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
args=()
[[ -z "$local_ip" || "$local_ip" == "$PUBLIC_IP" ]] || args+=(--nat-info "$local_ip:$PUBLIC_IP")
[[ -z "${TAG:-}" ]] || args+=(-P "$TAG")
# Keep the shared network namespace alive when refreshing the backend process.
worker= refresher=
stop(){
 [[ -z "$refresher" ]] || kill "$refresher" 2>/dev/null || true
 [[ -z "$worker" ]] || kill -TERM "$worker" 2>/dev/null || true
 wait || true
 exit 0
}
trap stop TERM INT
while :; do
 mtproto-proxy -u mtproxy -p 8888 -H 2398 -S "$SECRET" "${args[@]}" --aes-pwd /data/proxy-secret /data/proxy-multi.conf -M 1 -C 4096 & worker=$!
 (while sleep 86400; do if refresh; then kill -TERM "$worker"; exit; fi; done) & refresher=$!
 wait "$worker" || true
 kill "$refresher" 2>/dev/null || true
 wait "$refresher" 2>/dev/null || true
 sleep 3
done
