#!/usr/bin/env bash
set -Eeuo pipefail
# ПРОСТО WEB PROXY v8: WebMTProxy based on telegramdesktop/tproxy-server, existing Docker SelfSteal Caddy.
# Tested target: Ubuntu 24.04 x86_64. Does NOT install/alter SelfSteal.
DOMAIN=""; EMAIL=""; MODE="https"; TAG=""; BASE=/opt/prostoweb
RELAY_PORT=""; ADMIN_PORT=""
NCONF=/etc/nginx/sites-available/prostoweb; NLINK=/etc/nginx/sites-enabled/prostoweb
LOG=/var/log/prostoweb-install.log
red=$'\033[31m'; green=$'\033[32m'; cyan=$'\033[36m'; clear=$'\033[0m'
info(){ printf '%s[•]%s %s\n' "$cyan" "$clear" "$*"; }
warn(){ printf "%s[!]%s %s\n" "$cyan" "$clear" "$*"; }
ok(){ printf '%s[✓]%s %s\n' "$green" "$clear" "$*"; }
die(){ printf '%s[✗] %s%s\n' "$red" "$*" "$clear" >&2; exit 1; }
ask(){ local dest=$1 label=$2 default=${3:-} ans; read -r -p "$label${default:+ [$default]}: " ans; printf -v "$dest" '%s' "${ans:-$default}"; }
yesno(){ local reply; read -r -p "$1 [y/N]: " reply; [[ "$reply" =~ ^[Yy]$ ]]; }
port_busy(){ ss -H -ltn "( sport = :$1 )" | grep -q .; }
choose_relay_ports(){
 local p q
 for p in 8080 18081 18083 18085 18087 18089; do
  q=$((p+1))
  if ! port_busy "$p" && ! port_busy "$q"; then
   RELAY_PORT=$p; ADMIN_PORT=$q
   info "WEB relay :$RELAY_PORT, health :$ADMIN_PORT"
   return 0
  fi
 done
 die 'Нет свободной пары портов WEB relay/health.'
}
configured_admin_port(){
 local v
 v=$(sed -n 's/.*"admin_listen"[[:space:]]*:[[:space:]]*"127\.0\.0\.1:\([0-9]\+\)".*/\1/p' /etc/tproxy-server/config.json 2>/dev/null | head -1)
 printf '%s' "${v:-8081}"
}
valid_domain(){ [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$1" == *.* && "$1" != *..* ]]; }
backup(){ local b="$BASE/backups/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$b"; chmod 700 "$b"; for f in /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json /etc/mtproxy/mtproxy.env "$NCONF"; do [[ ! -f "$f" ]] || cp -a --parents "$f" "$b"; done; echo "Backup: $b"; }

install_new(){
 [[ $EUID -eq 0 ]] || die 'Запусти от root.'
 [[ -r /etc/os-release ]] || die 'Не найдена /etc/os-release.'
 . /etc/os-release
 [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 && "$(uname -m)" == x86_64 ]] || die 'Нужна Ubuntu 24.04 x86_64.'
 for f in /etc/tproxy-server/config.json /etc/systemd/system/mtproxy.service /etc/systemd/system/tproxy-server.service "$NCONF" "$NLINK"; do [[ ! -e "$f" && ! -L "$f" ]] || die "Обнаружена существующая установка: $f. Не перезаписываю."; done
 ask DOMAIN 'Домен WEB Proxy (A-запись должна вести на этот сервер)'
 DOMAIN=${DOMAIN,,}; valid_domain "$DOMAIN" || die 'Некорректный домен.'
 ask EMAIL 'Email для контакта (WebMTProxy)' 'admin@example.com'
 [[ "$EMAIL" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'Некорректный email.'
 local sel
 choose_transport sel 'Режим WEB Proxy при установке'
 case "$sel" in 1) MODE=https;; 2) MODE=https-lanes;; 3) MODE=websocket;; 4) MODE=websocket-lanes;; *) die 'Неверный режим.';; esac
 warn 'Спонсорский тег необязателен. Установка тега не гарантирует показ канала в Telegram WEB.'
 ask TAG 'Тег спонсора, 32 hex (Enter — пропустить)' ''
 [[ -z "$TAG" || "$TAG" =~ ^[0-9a-fA-F]{32}$ ]] || die 'Тег должен быть 32 hex.'
 local caddy_domain data certdir cert key ip dns
 command -v docker >/dev/null || die 'Сначала отдельно установи SelfSteal/Docker.'
 docker inspect caddy-selfsteal >/dev/null 2>&1 || die 'Не найден caddy-selfsteal. Сначала установи SelfSteal отдельно.'
 [[ "$(docker inspect -f '{{.State.Running}}' caddy-selfsteal)" == true ]] || die 'SelfSteal Caddy не запущен.'
 [[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' caddy-selfsteal)" == host ]] || die 'SelfSteal ожидается в host network.'
 [[ -s /opt/caddy/html/index.html && -f /opt/caddy/.env ]] || die 'Нет сайта или .env SelfSteal.'
 grep -Fxq "SELF_STEAL_DOMAIN=$DOMAIN" /opt/caddy/.env || die 'У SelfSteal другой домен. Проверь /opt/caddy/.env.'
 data=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' caddy-selfsteal)
 [[ -n "$data" && -d "$data" ]] || die 'Не найден том Caddy /data.'
 certdir="$data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN"
 cert="$certdir/$DOMAIN.crt"; key="$certdir/$DOMAIN.key"
 info 'Ожидание существующего сертификата Caddy (до 3 минут)'
 for i in $(seq 1 90); do [[ -s "$cert" && -s "$key" ]] && break; sleep 2; done
 [[ -s "$cert" && -s "$key" ]] || die 'Сертификат Caddy не найден.'
 openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || die 'Сертификат недействителен или скоро истечёт.'
 openssl x509 -in "$cert" -noout -ext subjectAltName | grep -Fq "DNS:$DOMAIN" || die 'Сертификат не соответствует домену.'
 for port in 443 2398 8888; do port_busy "$port" && die "Порт $port занят — установка остановлена."; done
 choose_relay_ports
 port_busy 80 || die 'Caddy SelfSteal не слушает 80.'
 ip=$(curl -4fsS --max-time 10 https://api.ipify.org) || die 'Не удалось получить IP.'
 dns=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u) || true
 grep -Fxq "$ip" <<< "$dns" || die "DNS $DOMAIN -> $dns, IP сервера $ip."
 if [[ -e /etc/nginx/sites-enabled/default && ! -L /etc/nginx/sites-enabled/default ]]; then die 'Нестандартный сайт Nginx default.'; fi
 if [[ -d /etc/nginx/sites-enabled ]] && find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 ! -name default | grep -q .; then die 'Nginx уже содержит активные сайты.'; fi
 printf '\nДомен: %s\nРежим: %s\nСайт: /opt/caddy/html\nTLS: сертификат SelfSteal\nСпонсор: %s\n' "$DOMAIN" "$MODE" "${TAG:-выключен}"
 yesno 'Начать установку? SelfSteal не будет изменён.' || return 0
 mkdir -p "$BASE"; chmod 700 "$BASE"
 : > "$LOG"; chmod 600 "$LOG"
 export DEBIAN_FRONTEND=noninteractive
 info 'Установка недостающих пакетов (без Docker и containerd)'
 apt-get update >> "$LOG" 2>&1
 apt-get install -y --no-install-recommends git curl ca-certificates nginx openssl python3 qrencode nftables >> "$LOG" 2>&1 || die "Ошибка apt. Последние строки: $(tail -n 5 "$LOG")"
 local tmp; tmp=$(mktemp -d)
 trap 'rm -rf "${tmp:-}"' EXIT
 info 'Загружаю исходники WebMTProxy и Telegram tproxy-server'
 if [[ -d "$BASE/WebMTProxy/.git" ]]; then
  [[ "$(git -C "$BASE/WebMTProxy" remote get-url origin)" == 'https://github.com/slowriverr/WebMTProxy.git' ]] || die 'Неверный существующий репозиторий WebMTProxy.'
  info 'Уже скачанные исходники WebMTProxy использую повторно'
 else
  git clone --depth 1 https://github.com/slowriverr/WebMTProxy.git "$BASE/WebMTProxy" >> "$LOG" 2>&1 || die 'Ошибка загрузки WebMTProxy.'
 fi
 if [[ -d "$BASE/tproxy-server/.git" ]]; then
  [[ "$(git -C "$BASE/tproxy-server" remote get-url origin)" == 'https://github.com/telegramdesktop/tproxy-server.git' ]] || die 'Неверный существующий репозиторий tproxy-server.'
  git -C "$BASE/tproxy-server" restore -- deploy/install.sh || die 'Не удалось восстановить исходный upstream install.sh'
  info 'Уже скачанные исходники tproxy-server использую повторно'
 else
  git clone --depth 1 https://github.com/telegramdesktop/tproxy-server.git "$BASE/tproxy-server" >> "$LOG" 2>&1 || die 'Ошибка загрузки tproxy-server.'
 fi
 local upstream="$BASE/tproxy-server/deploy/install.sh"
 cp "$upstream" "$tmp/upstream.original.sh"
 # Patch upstream installer without Caddy install/overwrite/start. FAIL CLOSED if source markers have changed.
 python3 - "$upstream" "$RELAY_PORT" "$ADMIN_PORT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
relay_port=sys.argv[2]; admin_port=sys.argv[3]
def remove(start,end):
 global s
 if s.count(start)!=1 or s.count(end)!=1: raise SystemExit('Upstream layout changed; refusing to patch Caddy integration')
 a=s.index(start); b=s.index(end)
 if b<=a: raise SystemExit('Bad upstream ordering')
 s=s[:a]+s[b:]
remove('caddy_version=2.11.4', '"$repository/deploy/install-mtproxy.sh"')
remove('install -m 0644 "$repository/deploy/Caddyfile" /etc/caddy/Caddyfile.tproxy\n', 'install -m 0644 "$repository/deploy/tproxy-server.service"')
# The web relay and MTProxy must remain; Caddy checks and starts must not.
needle='TPROXY_HOSTNAME="$hostname" TPROXY_SITE_ROOT=/srv/tproxy-site ACME_EMAIL="$email" \\\n\t/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile\n'
if s.count(needle)!=1: raise SystemExit('Upstream Caddy validation location changed; abort')
s=s.replace(needle,'')
for line in ('systemctl enable --now caddy.service\n','systemctl restart caddy.service\n'):
 if s.count(line)!=1: raise SystemExit('Upstream Caddy start markers changed; abort')
 s=s.replace(line,'')
# Avoid restrictive umask breaking MTProxy executable or Go tests (same upstream issue as WebMTProxy).
checks=[('"$repository/deploy/install-mtproxy.sh"','(umask 022; "$repository/deploy/install-mtproxy.sh")'),
 ('(cd "$repository" && "$go_binary" test ./...)','(umask 022; cd "$repository" && "$go_binary" test ./...)')]
for old,new in checks:
 if s.count(old)!=1: raise SystemExit('Upstream build/test block changed; abort')
 s=s.replace(old,new)
if s.count('127.0.0.1:8080') != 1 or s.count('127.0.0.1:8081') < 2:
 raise SystemExit('Upstream port structure changed, abort')
s=s.replace('127.0.0.1:8080', '127.0.0.1:'+relay_port)
s=s.replace('127.0.0.1:8081', '127.0.0.1:'+admin_port)
p.write_text(s)
PY
 bash -n "$upstream" || die 'Изменённый upstream-скрипт не прошёл bash -n.'
 if grep -Eq '/usr/local/bin/caddy|systemctl (enable|restart).*caddy\.service|/etc/caddy/Caddyfile' "$upstream"; then die 'Остались команды Caddy в upstream — остановка.'; fi
 info 'Готовлю Nginx: НЕ занимает :80 и НЕ перехватывает /?bridge='
 systemctl stop nginx >/dev/null 2>&1 || true
 if [[ -L /etc/nginx/sites-enabled/default ]]; then mkdir -p "$BASE/backups"; mv /etc/nginx/sites-enabled/default "$BASE/backups/nginx-default-link"; fi
 [[ -d /etc/nginx/sites-enabled ]] || mkdir -p /etc/nginx/sites-enabled
 local secret; secret=$(openssl rand -hex 16)
 # Upstream creates its own local backend and firewall; we disable ONLY its Caddy integration.
 info 'Сборка и установка backend MTProxy + tproxy-server (несколько минут)'
 if ! bash "$upstream" --hostname "$DOMAIN" --email "$EMAIL" --secret "dd$secret" --base-path none --site-dir /opt/caddy/html >> "$LOG" 2>&1; then
  tail -n 35 "$LOG" >&2; die "Backend не установился. Nginx не запущен; лог $LOG"; fi
 mkdir -p /etc/nginx/sites-available
 cat > "$NCONF" <<EOF
map \$http_upgrade \$prostoweb_upgrade { default upgrade; '' close; }
server {
 listen 443 ssl http2;
 server_name $DOMAIN;
 ssl_certificate $cert;
 ssl_certificate_key $key;
 client_max_body_size 2m;
 server_tokens off;
 location / {
  proxy_pass http://127.0.0.1:$RELAY_PORT;
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Forwarded-For \$remote_addr;
  proxy_set_header X-Forwarded-Proto https;
  proxy_set_header Upgrade \$http_upgrade;
  proxy_set_header Connection \$prostoweb_upgrade;
  proxy_connect_timeout 5s;
  proxy_send_timeout 90s;
  proxy_read_timeout 90s;
  proxy_request_buffering off;
  proxy_buffering off;
  proxy_next_upstream off;
 }
}
EOF
 ln -s "$NCONF" "$NLINK"
 if ! nginx -t; then rm -f "$NLINK" "$NCONF"; die 'Ошибка Nginx; конфигурация удалена, SelfSteal сохранён.'; fi
 systemctl enable --now nginx >> "$LOG" 2>&1 || die 'Ошибка запуска Nginx.'
 printf 'RELAY_PORT=%s\nADMIN_PORT=%s\n' "$RELAY_PORT" "$ADMIN_PORT" > "$BASE/ports.env"
 chmod 600 "$BASE/ports.env"
 local health=""; for i in $(seq 1 45); do if curl -fsS --max-time 2 http://127.0.0.1:$ADMIN_PORT/readyz >/dev/null; then health=ok; break; fi; sleep 2; done
 [[ "$health" == ok ]] || die 'Relay ещё не готов. Проверь systemctl status tproxy-server mtproxy.'
 info 'Устанавливаю штатную панель WebMTProxy'
 mkdir -p /opt/webmtproxy; cp -a "$BASE/WebMTProxy/." /opt/webmtproxy/
 install -m 755 /opt/webmtproxy/webmtproxy /usr/local/bin/webmtproxy
 webmtproxy mode "$MODE" >> "$LOG" 2>&1 || die 'Не удалось применить транспорт.'
 if [[ -n "$TAG" ]]; then webmtproxy sponsor "$TAG" >> "$LOG" 2>&1 || die 'Не удалось применить тег спонсора.'; fi
 cat > /etc/systemd/system/prostoweb-tls-refresh.service <<'EOF'
[Unit]
Description=Reload Nginx after SelfSteal Caddy certificate renewal
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/nginx -t && /bin/systemctl reload nginx'
EOF
 cat > /etc/systemd/system/prostoweb-tls-refresh.timer <<'EOF'
[Unit]
Description=Daily Nginx TLS certificate refresh
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
 systemctl daemon-reload; systemctl enable --now prostoweb-tls-refresh.timer >/dev/null
 [[ "$(curl -sS -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/")" == 200 ]] || die 'Сайт по HTTPS не отвечает 200.'
 ok 'Установка серверных компонентов завершена.'
 warn 'HTTPS проверен, но работу WEB Proxy необходимо подтвердить в Telegram-клиенте.'
 info "Ссылка: $(webmtproxy link)"
 info 'Меню: prstaweb'
 info "Журнал: $LOG"
 install -m 755 "$0" /usr/local/bin/prstaweb
 install -m 755 "$0" /usr/local/bin/prostoweb
}

backend_type(){
 if [[ -f /etc/tproxy-server/profiles.json && -f /etc/tproxy-server/config.json ]]; then echo webmtproxy
 elif [[ -f /etc/telemt/telemt.toml ]]; then echo telemt
 else echo none; fi
}
ensure_web(){ [[ "$(backend_type)" == webmtproxy ]] || { warn 'Эта команда доступна только для WebMTProxy. Установленный Telemt не изменён.'; return 1; }; }
active_domain(){
 if [[ "$(backend_type)" == webmtproxy ]]; then
  python3 -c 'import json;print(json.load(open("/etc/tproxy-server/config.json")).get("public_hostname","не задан"))' 2>/dev/null || echo неизвестно
 elif [[ "$(backend_type)" == telemt ]]; then sed -n 's/^host = "\([^"]*\)"/\1/p' /etc/telemt/telemt.toml | head -1
 else echo неизвестно; fi
}
active_mode(){
 if [[ "$(backend_type)" == webmtproxy ]]; then webmtproxy mode 2>/dev/null || echo неизвестно
 elif [[ "$(backend_type)" == telemt ]]; then sed -n 's/^carrier = "\([^"]*\)"/\1/p' /etc/telemt/telemt.toml | head -1
 else echo неизвестно; fi
}
site_root(){
 if [[ "$(backend_type)" == webmtproxy ]]; then
  python3 -c 'import json;print(json.load(open("/etc/tproxy-server/config.json")).get("public_dir", "/srv/tproxy-site"))' 2>/dev/null || echo /srv/tproxy-site
 elif [[ "$(backend_type)" == telemt ]]; then
  sed -n 's/^directory = "\([^"]*\)"/\1/p' /etc/telemt/telemt.toml | head -1
 fi
}
site_summary(){
 local dir domain title count code src
 dir=$(site_root); domain=$(active_domain)
 [[ -n "$dir" && -d "$dir" ]] || { warn 'Каталог сайта не найден'; return; }
 count=$(find "$dir" -type f | wc -l)
 title=$(sed -n 's/.*<title>\(.*\)<\/title>.*/\1/p' "$dir/index.html" 2>/dev/null | head -1)
 code=$(curl -k -sS --max-time 6 -o /dev/null -w '%{http_code}' "https://$domain/" || true)
 src='Пользовательский'; [[ -f /opt/caddy/html/index.html ]] && cmp -s /opt/caddy/html/index.html "$dir/index.html" && src='SelfSteal (копия)'
 printf '\n  Домен: %s\n  Источник: %s\n  Каталог: %s\n  Файлов: %s\n  Заголовок: %s\n  HTTPS: %s\n  Открыть: https://%s/\n' "$domain" "$src" "$dir" "$count" "${title:-не определён}" "$code" "$domain"
}
publish_site(){
 local src=$1 dir b dest old
 [[ -r "$src/index.html" ]] || { warn 'Нет index.html в исходном каталоге'; return 1; }
 [[ ! -L "$src" ]] || { warn 'Символьные ссылки как источник запрещены'; return 1; }
 ensure_web || { warn 'Для Telemt автоматическая публикация отключена во избежание нарушения WEB-сессий'; return 1; }
 dir=$(site_root); [[ "$dir" == /srv/tproxy-site ]] || { warn 'Нестандартный каталог. Публикация отменена'; return 1; }
 b="/root/prstaweb-site-backup-$(date +%Y%m%d-%H%M%S)"
 mkdir -m 700 "$b"; [[ ! -d "$dir" ]] || cp -a "$dir" "$b/site"
 if webmtproxy site "$src"; then ok "Сайт установлен. Резервная копия: $b"; else warn 'Ошибка публикации. Проверь состояние relay'; return 1; fi
}
menu_site(){
 local choice dir; while :; do
  select_menu 'ПРОСТО WEB PROXY · Сайт маскировки' choice \
   'Текущий сайт: заголовок, каталог, источник, HTTPS' \
   'Использовать сайт SelfSteal' 'Установить из каталога' \
   'Проверка HTML и ресурсов' 'Предыдущие резервные копии' 'Назад' || return 0
  case "$choice" in
   0) site_summary;;
   1) if yesno 'Скопировать сайт из /opt/caddy/html? Текущая WEB-сессия может прерваться'; then publish_site /opt/caddy/html || true; fi;;
   2) ask dir 'Каталог с index.html' ''; [[ -z "$dir" ]] || publish_site "$dir" || true;;
   3) site_summary; if [[ -f "$(site_root)/index.html" ]]; then
       info 'Встроенный CSS/JS может быть заблокирован CSP:'
       grep -Ein '<style|<script[^>]*>|https?://' "$(site_root)/index.html" | head -n 12 || true
      fi;;
   4) ls -dt /srv/tproxy-site.bak.* /root/prstaweb-site-backup-* 2>/dev/null | head -n 12 || true;;
   5) return 0;;
  esac
  wait_back
 done
}
menu_details(){
 local b d u st
 b=$(backend_type); d=$(active_domain)
 printf '\n  Движок: %s\n  Домен: %s\n  Режим: %s\n' "$b" "$d" "$(active_mode)"
 if [[ "$b" == webmtproxy ]]; then
  for u in nginx mtproxy tproxy-server tproxy-firewall; do st=$(systemctl is-active "$u" 2>/dev/null || true); printf '  %-20s %s\n' "$u" "$st"; done
  local admin; admin=$(configured_admin_port)
  printf '  Relay /readyz: '; curl -sS --max-time 3 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$admin/readyz" || true
 elif [[ "$b" == telemt ]]; then
  for u in nginx telemt; do st=$(systemctl is-active "$u" 2>/dev/null || true); printf '  %-20s %s\n' "$u" "$st"; done
 fi
 echo '  TLS:'; timeout 5 bash -c "echo | openssl s_client -connect 127.0.0.1:443 -servername '$d' 2>/dev/null | openssl x509 -noout -enddate" || true
 echo '  TCP 443:'; ss -Htn state established '( sport = :443 )' 2>/dev/null | wc -l
 warn 'TCP-соединения — не количество уникальных пользователей. HTTPS 200 — не проверка подключения Telegram.'
}
menu_services(){
 local choice unit; while :; do
  select_menu 'ПРОСТО WEB PROXY · Сервисы' choice 'Состояние сервисов' 'Перезапуск WEB-релея' 'Перезапуск backend MTProxy' 'Перезагрузка Nginx' 'Назад' || return 0
  case "$choice" in
   0) menu_details;;
   1) if [[ "$(backend_type)" == telemt ]]; then unit=telemt; else unit=tproxy-server; fi
      if yesno "Перезапустить $unit? Клиенты переподключатся"; then systemctl restart "$unit" && ok "$unit перезапущен" || warn 'Ошибка перезапуска'; fi;;
   2) if ensure_web && yesno 'Перезапустить MTProxy? Активные соединения прервутся'; then systemctl restart mtproxy && ok 'MTProxy перезапущен' || warn 'Ошибка'; fi;;
   3) if yesno 'Перезагрузить конфигурацию Nginx?'; then nginx -t && systemctl reload nginx && ok 'Nginx обновлён' || warn 'Ошибка'; fi;;
   4) return 0;;
  esac
  wait_back
 done
}
menu_diag(){
 local d; d=$(active_domain)
 info "DNS: $d"
 getent ahostsv4 "$d" | head -n 2 || true
 info 'Порты:'; ss -ltnp | grep -E ':(80|443|9443|8080|8081|18081|18082|18080)\b' || true
 info 'Nginx syntax:'; nginx -t || true
 info 'HTTPS:'; curl -sS --max-time 8 -o /dev/null -w 'HTTP %{http_code}; TLS verify %{ssl_verify_result}; TTFB %{time_starttransfer}s\n' "https://$d/" || true
 menu_details
}
install_menu_only(){
 [[ $EUID -eq 0 ]] || die 'Запусти от root'
 local target=/usr/local/bin/prstaweb cur
 cur=$(readlink -f "$0")
 if [[ "$cur" == "$target" ]]; then ok 'Меню уже установлено'; return; fi
 local stamp; stamp=$(date +%Y%m%d-%H%M%S)
 [[ ! -e "$target" ]] || cp -a "$target" "$target.bak.$stamp"
 install -m 0755 "$0" "$target"
 ok "Меню обновлено: $target (движок: $(backend_type)). Работающие службы не изменены."
}
show_current_secret(){
 local f=/etc/tproxy-server/profiles.json
 [[ -r "$f" ]] || { warn 'Конфигурация профилей отсутствует или недоступна.'; return 1; }
 python3 - "$f" <<'PYSECRET'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        config = json.load(handle)
    profiles = config.get('profiles', [])
    if not isinstance(profiles, list) or not profiles:
        raise ValueError('нет профилей')
    for profile in profiles:
        secret = profile.get('secret')
        if not isinstance(secret, str) or not secret:
            raise ValueError('секрет не обнаружен')
        print('Профиль:', profile.get('name', 'default'))
        print('Текущий секрет:', secret)
except (OSError, ValueError, KeyError, TypeError) as error:
    print('Ошибка чтения секрета:', error, file=sys.stderr)
    sys.exit(1)
PYSECRET
 warn 'Не отправляй секрет посторонним. Эта команда только показывает его, ничего не изменяя.'
}

show_modes(){
 cat <<'MODES'

╔══════════════════════════════════════════════════════════════════╗
║               ВЫБОР РЕЖИМА · WEB PROXY                           ║
╚══════════════════════════════════════════════════════════════════╝

 1) HTTPS — совместимость с iPhone, Android и ПК
    Обычные HTTPS-запросы. Максимальная совместимость,
    но при передаче медиа возможны задержки.

 2) HTTPS-Lanes — параллельный HTTPS
    Для ПК и клиентов с поддержкой lanes. Потоки независимы,
    полезно при одновременной передаче файлов. Не для iPhone.

 3) WebSocket — постоянное соединение
    Для клиентов с поддержкой WebSocket. Одно соединение,
    но высокая скорость не гарантируется. Не для iPhone.

 4) WebSocket-Lanes — независимые WebSocket-потоки
    Для поддерживающих клиентов. Может помочь с параллельной
    нагрузкой; поддержка зависит от клиента. Не для iPhone.

 Рекомендация: iPhone → 1; ПК/Android → 2 или 4 при поддержке.
MODES
}

select_menu(){
 local title=$1 outvar=$2; shift 2
 local items=("$@") index=0 key rest n=${#items[@]} i
 [[ -t 0 && -t 1 && -r /dev/tty ]] || { warn 'Требуется интерактивный терминал для меню.'; return 1; }
 while :; do
  printf '\033[2J\033[H' > /dev/tty
  printf '%s╔══════════════════════════════════════════════════════╗%s\n' "$cyan" "$clear" > /dev/tty
  printf '  %s%s%s\n' "$green" "$title" "$clear" > /dev/tty
  printf '%s╚══════════════════════════════════════════════════════╝%s\n\n' "$cyan" "$clear" > /dev/tty
  for ((i=0;i<n;i++)); do
   if ((i==index)); then printf '%s  ❯ %s%s\n' "$green" "${items[i]}" "$clear" > /dev/tty
   else printf '    %s\n' "${items[i]}" > /dev/tty; fi
  done
  printf '\n  ↑/↓ — выбор · Enter — открыть · Esc — назад/выход\n' > /dev/tty
  IFS= read -r -s -n1 key </dev/tty || return 1
  case "$key" in
   '') printf -v "$outvar" '%s' "$index"; return 0 ;;
   $'\033')
     rest=''; IFS= read -r -s -n1 -t 0.15 rest </dev/tty || true
     if [[ "$rest" == '[' || "$rest" == 'O' ]]; then
      IFS= read -r -s -n1 -t 0.15 rest </dev/tty || true
      case "$rest" in A) index=$(((index+n-1)%n));; B) index=$(((index+1)%n));; esac
     else return 2; fi ;;
   k|K) index=$(((index+n-1)%n));;
   j|J) index=$(((index+1)%n));;
  esac
 done
}
wait_back(){ printf '\nНажми Enter для возврата...' >/dev/tty; read -r _ </dev/tty || true; }
choose_transport(){
 local outvar=$1 title=$2 item
 local choices=(
  'HTTPS — iPhone / все платформы · максимальная совместимость'
  'HTTPS-Lanes — ПК / поддерживаемые клиенты · параллельный HTTPS'
  'WebSocket — поддерживаемые клиенты · одно постоянное соединение'
  'WebSocket-Lanes — поддерживаемые клиенты · параллельные потоки'
  'Назад'
 )
 select_menu "$title" item "${choices[@]}" || return 1
 case "$item" in
  0) printf -v "$outvar" '%s' 1;; 1) printf -v "$outvar" '%s' 2;;
  2) printf -v "$outvar" '%s' 3;; 3) printf -v "$outvar" '%s' 4;;
  *) return 1;;
 esac
}

menu_access(){
 local choice
 while :; do
  select_menu 'ПРОСТО WEB PROXY · Доступ' choice \
   'Показать ссылку' 'Показать QR-код' 'Показать действующий секрет' 'Сменить секрет' 'Назад' || return 0
  case "$choice" in
   0) webmtproxy link || true;;
   1) if command -v qrencode >/dev/null; then webmtproxy qr || true; else warn 'QR недоступен: установи qrencode'; fi;;
   2) show_current_secret || true;;
   3) if yesno 'Сменить секрет? ВСЕ старые ссылки перестанут работать!'; then webmtproxy rotate-secret || true; else info 'Отменено'; fi;;
   4) return 0;;
  esac
  wait_back
 done
}
menu_sponsor(){
 local choice tag
 while :; do
  select_menu 'ПРОСТО WEB PROXY · Спонсорский канал' choice \
   'Показать установленный тег' 'Установить тег от @MTProxybot' 'Отключить тег' 'Назад' || return 0
  case "$choice" in
   0) webmtproxy sponsor || true;;
   1) ask tag 'Введи ad_tag (32 hex)' ''; [[ -z "$tag" ]] || webmtproxy sponsor "$tag" || true;;
   2) if yesno 'Отключить спонсорский тег?'; then webmtproxy sponsor off || true; fi;;
   3) return 0;;
  esac
  warn 'Установка тега не подтверждает фактический показ канала в Telegram WEB.'
  wait_back
 done
}
menu_transport(){
 local choice mode
 while :; do
  select_menu 'ПРОСТО WEB PROXY · Транспорт' choice \
   'Показать текущий режим' 'Изменить режим (iPhone / быстрый)' 'Подсказка по режимам' 'Назад' || return 0
  case "$choice" in
   0) webmtproxy mode || true;;
   1) if choose_transport mode 'Выбери новый WEB-транспорт'; then
        case "$mode" in 1) mode=https;; 2) mode=https-lanes;; 3) mode=websocket;; 4) mode=websocket-lanes;; esac
        if webmtproxy mode "$mode"; then ok 'Режим применён. Переподключи клиент.'; else warn 'Не удалось изменить режим'; fi
      fi;;
   2) show_modes;;
   3) return 0;;
  esac
  wait_back
 done
}

# Arrow-key selector: Up/Down, Enter, Esc, and optional j/k.
# Uses /dev/tty, so it works when stdout is redirected or installation uses curl.
main_menu(){
 [[ $EUID -eq 0 ]] || die 'Нужен root.'
 local choice
 while :; do
  select_menu 'ПРОСТО WEB PROXY · Главное меню v8' choice \
   'Обзор и состояние' 'Подключение, QR, секрет' 'Режим передачи' \
   'Спонсорский канал' 'Сайт маскировки' 'Управление сервисами' \
   'Диагностика и сеть' 'Резервная копия' \
   'Установка нового WebMTProxy' 'Обновить меню на этом сервере' 'Выход' || break
  case "$choice" in
   0) menu_details; wait_back;;
   1) if ensure_web; then menu_access; else warn 'Telemt: текущая ссылка находится в журнале или /root/telegram-webproxy.txt'; wait_back; fi;;
   2) if ensure_web; then menu_transport; else info "Telemt: $(active_mode); смена режима недоступна в панели WebMTProxy"; wait_back; fi;;
   3) if ensure_web; then menu_sponsor; else warn 'В Telemt рекламный тег настраивается отдельно; панель его не изменяет'; wait_back; fi;;
   4) menu_site;;
   5) menu_services;;
   6) menu_diag; wait_back;;
   7) if [[ "$(backend_type)" == webmtproxy ]]; then backup; else info 'Telemt: используйте снимок VPS для полного отката'; fi; wait_back;;
   8) if [[ "$(backend_type)" != none ]]; then warn 'Прокси уже установлен. Чтобы избежать потери настроек, переустановка запрещена.'; else install_new || true; fi; wait_back;;
   9) install_menu_only; wait_back;;
   10) break;;
  esac
 done
 printf '\n[✓] Выход из ПРОСТО WEB PROXY\n'
}
# Explicit install/update, never changes the running proxy or Caddy.
case "${1:-}" in
 --install-menu|--update-menu) install_menu_only; exit 0;;
 --status) menu_details; exit 0;;
 --site-status) site_summary; exit 0;;
esac
# If executed from a downloaded file, install launcher. Does not restart services.
if [[ $EUID -eq 0 && "$(backend_type)" != none && "$(readlink -f "$0")" != /usr/local/bin/prstaweb ]]; then
 install_menu_only
fi
main_menu
