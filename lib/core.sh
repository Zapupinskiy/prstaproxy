#!/usr/bin/env bash
VERSION=$(cat "$APP/VERSION")
REPO=https://github.com/Zapupinskiy/prstaproxy.git
PREV_UP= PREV_DOWN= PREV_TIME=
compose(){ docker compose --project-name prostoweb --project-directory "$BASE" -f "$BASE/compose.yaml" "$@"; }
require_root(){ [[ $EUID -eq 0 ]] || die 'Нужен root: sudo zlp'; }
register_commands(){
 require_root
 local name
 for name in zlp prstaweb prostoweb; do
  cat > "/usr/local/bin/$name" <<EOF
#!/usr/bin/env bash
exec bash "$APP/prstaproxy.sh" "\$@"
EOF
  chmod 755 "/usr/local/bin/$name"
 done
}
# A failed stage is waited on explicitly; background jobs cannot kill the menu.
stage(){
 local number=$1 title=$2; shift 2
 local start=$SECONDS pid rc=0 frame=0 frames='|/-\'
 printf '[%s/7] %s\n' "$number" "$title"
 APP="$APP" BASE="$BASE" LOG="$LOG" DOMAIN="$DOMAIN" MODE="$MODE" \
  bash -c 'source "$APP/prstaproxy.sh"; "$@"' _ "$@" >> "$LOG" 2>&1 & pid=$!
 while kill -0 "$pid" 2>/dev/null; do
  printf '\r  %s %s · %02d:%02d' "${frames:frame%4:1}" "$title" "$(((SECONDS-start)/60))" "$(((SECONDS-start)%60))"
  frame=$((frame+1)); sleep 0.2
 done
 wait "$pid" || rc=$?
 printf '\r  %s %s · %02d:%02d\n' "$([[ $rc == 0 ]] && echo '✓' || echo '✗')" "$title" "$(((SECONDS-start)/60))" "$(((SECONDS-start)%60))"
 if ((rc)); then tail -n 25 "$LOG" >&2; warn "Этап $number завершился с ошибкой. Журнал: $LOG"; return "$rc"; fi
}
dependencies(){
 export DEBIAN_FRONTEND=noninteractive
 apt-get update
 apt-get install -y --no-install-recommends curl git ca-certificates python3 openssl iproute2 dnsutils qrencode
 if ! command -v docker >/dev/null; then apt-get install -y docker.io; fi
 if ! docker compose version >/dev/null 2>&1; then
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then apt-get install -y docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then apt-get install -y docker-compose-plugin
  else
   local temporary checksum
   temporary=$(mktemp -d)
   curl -fsSL --retry 3 https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-x86_64 -o "$temporary/docker-compose"
   curl -fsSL --retry 3 https://github.com/docker/compose/releases/download/v2.39.4/checksums.txt -o "$temporary/checksums.txt"
   checksum=$(awk '{sub(/^\*/, "", $2)} $2=="docker-compose-linux-x86_64" {print $1}' "$temporary/checksums.txt")
   [[ "$checksum" =~ ^[0-9a-f]{64}$ ]]
   printf '%s  %s\n' "$checksum" "$temporary/docker-compose" | sha256sum -c -
   install -D -m 755 "$temporary/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
   rm -rf -- "$temporary"
  fi
 fi
 systemctl enable --now docker
 docker info >/dev/null
}
check_dns(){
 local ip dns aaaa
 ip=$(curl -4fsS --max-time 10 https://api.ipify.org)
 [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
 dns=$(dig +short A "$DOMAIN" | grep -E '^[0-9.]+$' | sort -u)
 [[ -n "$dns" ]] || { echo 'A-запись не найдена'; return 1; }
 [[ "$dns" == "$ip" ]] || { echo "DNS: $dns; IP сервера: $ip. Все A-записи должны указывать на сервер (без CDN)."; return 1; }
 aaaa=$(dig +short AAAA "$DOMAIN" | grep ':' || true)
 [[ -z "$aaaa" ]] || { echo 'Для этой IPv4 установки удалите AAAA-запись домена.'; return 1; }
 printf '%s\n' "$ip" > "$BASE/public-ip"
 echo "DNS подтверждён: $DOMAIN → $ip"
}
write_deployment(){
 python3 "$APP/lib/config.py" "$BASE" init "$DOMAIN" "$MODE" "$(cat "$BASE/public-ip")"
 mkdir -p "$BASE/site"
 printf '<!doctype html><html lang="ru"><meta charset="utf-8"><title>%s</title><h1>%s</h1><p>Сайт работает.</p></html>\n' "$DOMAIN" "$DOMAIN" > "$BASE/site/index.html"
 printf '<!doctype html><title>404</title><h1>Страница не найдена</h1>\n' > "$BASE/site/404.html"
 cat > "$BASE/Caddyfile" <<EOF
{
 admin off
 servers {
  protocols h1 h2
  timeouts {
   read_header 10s
   read_body 60s
  }
 }
}
$DOMAIN {
 reverse_proxy 127.0.0.1:8080 {
  transport http {
   response_header_timeout 40s
  }
 }
}
EOF
 write_compose
}
write_compose(){
 cat > "$BASE/compose.yaml" <<EOF
services:
  mtproxy:
    image: prostoweb-mtproxy:local
    build:
      context: $APP/docker
      dockerfile: mtproxy.Dockerfile
    restart: unless-stopped
    volumes:
      - ./config:/config:ro
      - mtproxy-data:/data
    networks: [backend]
    ports: ['80:80', '443:443']
    logging: {driver: json-file, options: {max-size: 10m, max-file: '3'}}
  relay:
    image: prostoweb-relay:local
    build:
      context: $APP/docker
      dockerfile: relay.Dockerfile
    restart: unless-stopped
    depends_on: [mtproxy]
    volumes:
      - ./config:/etc/tproxy-server:ro
      - ./site:/srv/tproxy-site:ro
    network_mode: service:mtproxy
    healthcheck:
      test: [CMD, curl, -fsS, http://127.0.0.1:8081/readyz]
      interval: 10s
      timeout: 3s
      retries: 6
    logging: {driver: json-file, options: {max-size: 10m, max-file: '3'}}
  caddy:
    image: caddy:2.11.4
    restart: unless-stopped
    depends_on: [relay]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    network_mode: service:mtproxy
    logging: {driver: json-file, options: {max-size: 10m, max-file: '3'}}
networks:
  backend:
volumes:
  mtproxy-data:
  caddy-data:
  caddy-config:
EOF
 compose config --quiet
}
verify_deployment(){
 local attempt domain
 domain=$(active_domain)
 for ((attempt=0;attempt<90;attempt++)); do
  if compose exec -T relay curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null &&
     curl -fsS --max-time 3 --resolve "$domain:443:127.0.0.1" "https://$domain/" >/dev/null; then return 0; fi
  sleep 2
 done
 echo 'Не прошла проверка relay/TLS. Проверьте DNS, доступность 80/443 и docker compose logs.'
 return 1
}
install_new(){
 require_root
 source /etc/os-release
 [[ "$ID" == ubuntu || "$ID" == debian ]] || { warn 'Нужна Ubuntu/Debian с systemd'; return 1; }
 [[ $(uname -m) == x86_64 ]] || { warn 'MTProxy требует x86_64'; return 1; }
 if [[ "$(backend_type)" == containers && ! -f "$BASE/.installed" ]]; then
  info 'Продолжаю незавершённую установку, сохраняя домен и секрет.'
  touch "$LOG"; chmod 600 "$LOG"
  stage 4 'Проверка сохранённой конфигурации' write_compose || return 1
  stage 5 'Сборка MTProxy и WEB-релея' compose build --pull || return 1
  stage 6 'Запуск контейнеров и получение TLS' compose up -d || return 1
  stage 7 'Проверка готовности и HTTPS' verify_deployment || return 1
  touch "$BASE/.installed"
  register_commands
  ok "Установка $VERSION завершена"
  webmtproxy link
  return 0
 fi
 if [[ "$(backend_type)" != none ]]; then warn 'Прокси уже установлен. Используй zlp обновить; настройки сохраняются.'; return 0; fi
 mkdir -p "$BASE"; chmod 700 "$BASE"
 touch "$LOG"; chmod 600 "$LOG"
 stage 1 'Зависимости установщика и Docker Compose' dependencies || return 1
 local port
 for port in 80 443; do
  if port_busy "$port"; then warn "Порт $port занят. Освободи его перед установкой."; return 1; fi
 done
 printf '[2/7] Домен и проверка DNS\n'
 while :; do
  ask DOMAIN 'Домен прокси (без https://)'
  DOMAIN=${DOMAIN,,}
  if ! valid_domain "$DOMAIN"; then warn 'Некорректный домен'; continue; fi
  stage 2 'Проверка DNS → IPv4 сервера' check_dns && break
  yesno 'Повторить ввод домена?' || return 1
 done
 local selected start=$SECONDS
 printf '[3/7] Выбор режима\n'
 select_menu 'Установка · выбор режима' selected 'iPhone — https' 'Остальные устройства — https-lanes' || return 1
 case "$selected" in 0) MODE=https;; 1) MODE=https-lanes;; esac
 printf '  ✓ Режим %s · %s с\n' "$MODE" "$((SECONDS-start))"
 stage 4 'Конфигурация контейнеров и секреты' write_deployment || return 1
 stage 5 'Сборка MTProxy и WEB-релея' compose build --pull || return 1
 stage 6 'Запуск контейнеров и получение TLS' compose up -d || return 1
 stage 7 'Проверка готовности и HTTPS' verify_deployment || return 1
 touch "$BASE/.installed"
 register_commands
 ok "ПРОСТОВПН WEB PROXY $VERSION установлен. Меню: zlp"
 webmtproxy link
}
webmtproxy(){
 if [[ "$(backend_type)" != containers ]]; then command webmtproxy "$@"; return; fi
 local action=${1:-link}; shift || true
 case "$action" in
  link|mode|sponsor)
   python3 "$APP/lib/config.py" "$BASE" "$action" "$@" || return 1
   if (($#)); then
    if [[ "$action" == sponsor ]]; then compose up -d --force-recreate; else compose restart relay; fi
   fi;;
  qr) python3 "$APP/lib/config.py" "$BASE" link | qrencode -t UTF8;;
  *) warn 'Эта операция недоступна для контейнерной установки'; return 1;;
 esac
}
dashboard_line(){
 local chunk
 printf -v chunk "$@"
 DASH_TEXT+=$chunk
}
dashboard(){
 if [[ -n "${DASH_TIME:-}" ]] && (($(date +%s)-DASH_TIME<10)); then printf '%s' "$DASH_TEXT"; return; fi
 DASH_TEXT=
 local type domain mode admin metrics users up down now rx='—' tx='—' unit state
 type=$(backend_type); domain=$(active_domain); mode=$(active_mode)
 if [[ "$type" == containers ]]; then admin=18082; else admin=$(configured_admin_port); fi
 if [[ "$type" == containers ]]; then
  metrics=$(timeout 2 docker exec prostoweb-relay-1 curl -fsS --max-time 1 http://127.0.0.1:8081/metrics 2>/dev/null || true)
 else metrics=$(curl -fsS --max-time 1 "http://127.0.0.1:$admin/metrics" 2>/dev/null || true); fi
 users=$(awk '$1=="tproxy_sessions_live" {print $2}' <<< "$metrics")
 up=$(awk '$1=="tproxy_bytes_up_total" {print $2}' <<< "$metrics")
 down=$(awk '$1=="tproxy_bytes_down_total" {print $2}' <<< "$metrics")
 now=$(date +%s)
 if [[ "$up" =~ ^[0-9]+$ && "$down" =~ ^[0-9]+$ ]]; then
  if [[ -n "$PREV_TIME" ]] && ((now>PREV_TIME && up>=PREV_UP && down>=PREV_DOWN)); then
   rx=$(awk -v n="$((up-PREV_UP))" -v t="$((now-PREV_TIME))" 'BEGIN{printf "%.1f КиБ/с",n/t/1024}')
   tx=$(awk -v n="$((down-PREV_DOWN))" -v t="$((now-PREV_TIME))" 'BEGIN{printf "%.1f КиБ/с",n/t/1024}')
  fi
  PREV_UP=$up; PREV_DOWN=$down; PREV_TIME=$now
 else PREV_TIME=; fi
 dashboard_line '  Дашборд · %s · обновление каждые 10 секунд\n' "$(date +%T)"
 dashboard_line '  Активный WEB-прокси: %s · режим: %s\n' "$type" "$mode"
 dashboard_line '  Пользователи (активные сессии): %s\n' "${users:-нет данных}"
 dashboard_line '  Приём от клиентов: %s · Отдача клиентам: %s\n' "$rx" "$tx"
 if [[ "$type" == containers ]]; then
  for unit in caddy relay mtproxy; do
   state=$(timeout 2 docker inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' "prostoweb-$unit-1" 2>/dev/null || echo недоступен)
   dashboard_line '  Контейнер %-8s %s\n' "$unit" "$state"
  done
  dashboard_line '  Служба Docker: %s\n' "$(systemctl is-active docker 2>/dev/null || true)"
 elif [[ "$type" != none ]]; then
  for unit in nginx mtproxy tproxy-server telemt; do
   dashboard_line '  Служба %-13s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
  done
 else dashboard_line '  Контейнеры и службы прокси ещё не установлены\n'; fi
 if [[ "$type" == containers || "$type" == webmtproxy ]]; then
  dashboard_line '  Подключение: %s\n' "$(webmtproxy link 2>/dev/null || echo недоступно)"
  dashboard_line '  Сайт: https://%s/\n' "$domain"
 fi
 dashboard_line '  Сессии ≠ уникальные люди; скорости — полезный трафик WEB-релея.\n'
 DASH_TIME=$(date +%s)
 printf '%s' "$DASH_TEXT"
}
menu_management(){
 local choice
 while :; do
  select_menu 'Управление' choice 'Режим передачи' 'Спонсорский канал' 'Управление сервисами' 'Обновить' 'Назад' || return 0
  case "$choice" in
   0) ensure_web && menu_transport;;
   1) ensure_web && menu_sponsor;;
   2) if [[ "$(backend_type)" == containers ]]; then menu_containers; else menu_services; fi;;
   3) update_project || warn 'Обновление не завершено'; wait_back;;
   4) return 0;;
  esac
 done
}
menu_containers(){
 local choice
 while :; do
  select_menu 'Управление сервисами' choice 'Состояние' 'Перезапустить все контейнеры' 'Запустить' 'Остановить' 'Журнал' 'Назад' || return 0
  case "$choice" in
   0) compose ps;; 1) compose up -d --force-recreate;; 2) compose up -d;;
   3) compose stop;; 4) compose logs --tail 60;; 5) return 0;;
  esac
  wait_back
 done
}
update_project(){
 require_root
 command -v git >/dev/null || { warn 'Сначала установи git'; return 1; }
 local temp release old_app=$APP stamp old_compose= rolled=0
 mkdir -p "$BASE/app/releases" "$BASE/backups"
 temp=$(mktemp -d "$BASE/app/releases/update.XXXXXX")
 if ! git clone --depth 1 "$REPO" "$temp"; then rm -rf -- "$temp"; return 1; fi
 if ! bash -n "$temp/prstaproxy.sh" "$temp/lib/core.sh" || ! python3 -m py_compile "$temp/lib/config.py"; then
  rm -rf -- "$temp"; warn 'Обновление не прошло проверку'; return 1
 fi
 release="$BASE/app/releases/$(git -C "$temp" rev-parse HEAD)"
 if [[ ! -d "$release" ]]; then mv "$temp" "$release"; else rm -rf -- "$temp"; fi
 stamp=$(date +%Y%m%d-%H%M%S)
 if [[ "$(backend_type)" == containers ]]; then
  mkdir -m 700 "$BASE/backups/$stamp"
  cp -a "$BASE/config" "$BASE/compose.yaml" "$BASE/Caddyfile" "$BASE/backups/$stamp/"
  old_compose="$BASE/backups/$stamp/compose.yaml"
  local image
  for image in relay mtproxy; do docker tag "prostoweb-$image:local" "prostoweb-$image:rollback-$stamp" || return 1; done
  APP=$release
  if ! write_compose || ! compose build --pull || ! compose up -d --force-recreate || ! verify_deployment; then
   for image in relay mtproxy; do docker tag "prostoweb-$image:rollback-$stamp" "prostoweb-$image:local"; done
   cp "$old_compose" "$BASE/compose.yaml"
   compose up -d --force-recreate || rolled=1
   APP=$old_app
   warn "Обновление не прошло проверку. Восстановлены предыдущие образы и Compose (ошибка отката: $rolled)."
   return 1
  fi
  APP=$old_app
 fi
 ln -sfn "$release" "$BASE/app/current.new"
 mv -Tf "$BASE/app/current.new" "$BASE/app/current"
 bash "$release/prstaproxy.sh" --install-menu
 ok "Проект и команды обновлены до $(cat "$release/VERSION"). Обновление: zlp обновить"
 if [[ "$(backend_type)" != containers && "$(backend_type)" != none ]]; then
  info 'Установка прежней версии: обновлены панель и команды. Перенос systemd в Docker требует отдельной миграции.'
 fi
 exec bash "$release/prstaproxy.sh"
}
