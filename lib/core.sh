#!/usr/bin/env bash
VERSION=$(cat "$APP/VERSION")
REPO=https://github.com/Zapupinskiy/prstaproxy.git
SELFSTEAL_DIR=${SELFSTEAL_DIR:-/opt/caddy}
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
 if [[ -f "$BASE/.selfsteal" ]]; then
  cat > /usr/local/bin/selfsteal <<EOF
#!/usr/bin/env bash
exec bash "$APP/lib/selfsteal.sh" "\$@"
EOF
  chmod 755 /usr/local/bin/selfsteal
 fi
}
# A failed stage is waited on explicitly; background jobs cannot kill the menu.
stage(){
 local number=$1 title=$2; shift 2
 print_step "$number" "$title"
 local rc=0
 run_live_log env APP="$APP" BASE="$BASE" LOG="$LOG" DOMAIN="$DOMAIN" MODE="$MODE" \
  INSTALL_SECRET="${INSTALL_SECRET:-}" INSTALL_TAG="${INSTALL_TAG:-}" SELFSTEAL_DIR="$SELFSTEAL_DIR" \
  bash -c 'source "$APP/prstaproxy.sh"; "$@"' _ "$@" || rc=$?
 if ((rc)); then screen_finish error; else screen_finish success; fi
 return "$rc"
}

dependencies(){
 export DEBIAN_FRONTEND=noninteractive
 local package status missing=()
 for package in curl git ca-certificates python3 openssl iproute2 dnsutils qrencode nano jq; do
  status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
  if [[ "$status" == 'install ok installed' ]]; then ui_status success "$package уже установлен"
  else missing+=("$package"); ui_status warning "$package отсутствует"; fi
 done
 if ! command -v docker >/dev/null; then missing+=(docker.io); fi
 if ((${#missing[@]})) || ! docker compose version >/dev/null 2>&1; then
  apt-get update || return 1
 fi
 if ((${#missing[@]})); then
  apt-get install -y --no-install-recommends "${missing[@]}" || return 1
 else ui_status skipped 'Установка системных пакетов не требуется'; fi
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
 [[ -z "${INSTALL_SECRET:-}" ]] || python3 "$APP/lib/config.py" "$BASE" secret "$INSTALL_SECRET"
 [[ -z "${INSTALL_TAG:-}" ]] || python3 "$APP/lib/config.py" "$BASE" sponsor "$INSTALL_TAG"
 prepare_selfsteal
 write_compose
}
prepare_selfsteal(){
 local domain
 domain=$(python3 "$APP/lib/config.py" "$BASE" domain)
 if [[ -f "$SELFSTEAL_DIR/docker-compose.yml" && ! -f "$BASE/.selfsteal" ]]; then
  DOMAIN=$domain
  validate_existing_selfsteal || return 1
  backup_existing_selfsteal || return 1
 fi
 if [[ -f /opt/nginx-selfsteal/docker-compose.yml ]]; then
  echo 'Обнаружен SelfSteal Nginx. Общая установка требует Caddy; автоматическая замена Nginx отключена.'; return 1
 fi
 if [[ -f "$SELFSTEAL_DIR/.env" ]]; then
  grep -Fxq "SELF_STEAL_DOMAIN=$domain" "$SELFSTEAL_DIR/.env" || { echo 'У существующего SelfSteal другой домен'; return 1; }
  grep -Fxq 'SELF_STEAL_PORT=9443' "$SELFSTEAL_DIR/.env" || { echo 'Существующий SelfSteal должен использовать порт 9443'; return 1; }
 fi
 # Preserve an operator site while migrating an existing 0.2/0.3 installation.
 if [[ ! -s "$SELFSTEAL_DIR/html/index.html" && -s "$BASE/site/index.html" ]]; then
  mkdir -p "$SELFSTEAL_DIR/html"
  cp -a "$BASE/site/." "$SELFSTEAL_DIR/html/"
 fi
 if [[ -f "$BASE/selfsteal-existing.json" ]]; then
  ui_status skipped 'SelfSteal уже установлен: установка Caddy и шаблона сайта пропущена'
 else
  BASE="$BASE" SELFSTEAL_DIR="$SELFSTEAL_DIR" bash "$APP/lib/selfsteal.sh" --zlp-prepare "$domain" || return 1
 fi
 python3 "$APP/lib/selfsteal_config.py" "$BASE" "$SELFSTEAL_DIR"
}
snapshot_deployment(){
 local destination=$1 file
 mkdir -m 700 "$destination"
 cp -a "$BASE/config" "$BASE/compose.yaml" "$destination/"
 for file in Caddyfile .selfsteal .installed selfsteal-existing.json .selfsteal-handoff; do
  [[ ! -e "$BASE/$file" ]] || cp -a "$BASE/$file" "$destination/"
 done
 if [[ -d "$SELFSTEAL_DIR" ]]; then cp -a "$SELFSTEAL_DIR" "$destination/selfsteal"; fi
}
restore_deployment(){
 local destination=$1
 cp -a "$destination/config/." "$BASE/config/"
 cp "$destination/compose.yaml" "$BASE/compose.yaml"
 if [[ -f "$destination/.selfsteal" ]]; then cp "$destination/.selfsteal" "$BASE/.selfsteal"
 else rm -f "$BASE/.selfsteal"; fi
 [[ ! -f "$destination/Caddyfile" ]] || cp "$destination/Caddyfile" "$BASE/Caddyfile"
 if [[ -d "$destination/selfsteal" ]]; then cp -a "$destination/selfsteal/." "$SELFSTEAL_DIR/"
 else
  # Only remove the generated bridge/config; downloaded operator content is kept.
  rm -f "$SELFSTEAL_DIR/Caddyfile" "$SELFSTEAL_DIR/zlp.Caddyfile" "$SELFSTEAL_DIR/.env" "$SELFSTEAL_DIR/docker-compose.yml"
 fi
}
integrate_existing(){
 require_root
 local destination="$BASE/backups/selfsteal-$(date +%Y%m%d-%H%M%S)-$$" rc=0
 touch "$LOG"; chmod 600 "$LOG"
 stage 1 'Общие зависимости установщика и SelfSteal' dependencies || return 1
 mkdir -p "$BASE/backups"
 snapshot_deployment "$destination" || return 1
 info 'Объединяю существующий WEB Proxy с SelfSteal. Домен, секрет и сайт сохраняются.'
 if stage 7 'Нативная установка SelfSteal и общий сайт' resume_deployment &&
    stage 9 'Проверка Caddy и запуск общих контейнеров' start_deployment --force-recreate &&
    stage 7 'Проверка WEB Proxy и SelfSteal' verify_deployment; then
  register_commands
  ok "SelfSteal интегрирован. Резервная копия: $destination"
  return 0
 fi
 restore_deployment "$destination" || rc=1
 compose up -d --force-recreate || rc=1
 warn "Интеграция не прошла проверку; восстановлена прежняя конфигурация (ошибка отката: $rc)."
 return 1
}
resume_deployment(){
 prepare_selfsteal
 write_compose
}
build_deployment(){
 compose build --pull || return 1
 if [[ -f "$BASE/.selfsteal" && ! -f "$BASE/selfsteal-existing.json" ]]; then BASE="$BASE" SELFSTEAL_DIR="$SELFSTEAL_DIR" bash "$APP/lib/selfsteal.sh" --zlp-image; fi
}
start_deployment(){
 if [[ -f "$BASE/.selfsteal" ]]; then
  BASE="$BASE" SELFSTEAL_DIR="$SELFSTEAL_DIR" bash "$APP/lib/selfsteal.sh" --zlp-validate || return 1
 fi
 handoff_existing_selfsteal || return 1
 compose up -d "$@"
}

write_selfsteal_compose(){
 cat > "$BASE/compose.yaml" <<EOF
name: prostoweb
services:
  mtproxy:
    image: prostoweb-mtproxy:local
    build:
      context: $APP/docker
      dockerfile: mtproxy.Dockerfile
    restart: unless-stopped
    volumes:
      - $BASE/config:/config:ro
      - mtproxy-data:/data
    networks: [backend]
    ports: ['80:80', '443:443', '127.0.0.1:9443:9443']
    logging: {driver: json-file, options: {max-size: 10m, max-file: '3'}}
  relay:
    image: prostoweb-relay:local
    build:
      context: $APP/docker
      dockerfile: relay.Dockerfile
    restart: unless-stopped
    depends_on: [mtproxy]
    volumes:
      - $BASE/config:/etc/tproxy-server:ro
    network_mode: service:mtproxy
    healthcheck:
      test: [CMD, curl, -fsS, http://127.0.0.1:8081/readyz]
      interval: 10s
      timeout: 3s
      retries: 6
    logging: {driver: json-file, options: {max-size: 10m, max-file: '3'}}
  caddy:
    image: caddy:2.11.4
    container_name: caddy-selfsteal
    restart: unless-stopped
    depends_on: [relay]
    env_file: [$SELFSTEAL_DIR/.env]
    volumes:
      - $SELFSTEAL_DIR/Caddyfile:/etc/caddy/Caddyfile:ro
      - $SELFSTEAL_DIR/zlp.Caddyfile:/etc/caddy/zlp.Caddyfile:ro
      - $SELFSTEAL_DIR/html:/var/www/html:ro
      - $SELFSTEAL_DIR/logs:/var/log/caddy
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
 if [[ -f "$BASE/selfsteal-existing.json" ]]; then configure_existing_volumes || return 1; fi
 compose config --quiet
 # Native SelfSteal commands operate the same project from their original path.
 ln -sfn "$BASE/compose.yaml" "$SELFSTEAL_DIR/docker-compose.yml"
}
write_compose(){
 if [[ -f "$BASE/.selfsteal" ]]; then write_selfsteal_compose; return; fi
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
     curl -fsS --max-time 3 --resolve "$domain:443:127.0.0.1" "https://$domain/" >/dev/null; then
   if [[ ! -f "$BASE/.selfsteal" ]] || compose exec -T relay curl -fsS --max-time 2 http://127.0.0.1:18083/ >/dev/null; then return 0; fi
  fi
  sleep 2
 done
 echo 'Не прошла проверка relay/TLS. Проверьте DNS, доступность 80/443 и docker compose logs.'
 return 1
}
install_new(){
 wizard_reset
 terminal_clear
 local rc=0
 install_flow || rc=$?
 if ((rc)); then rollback_existing_selfsteal || warn 'Не удалось восстановить SelfSteal; резервная копия сохранена в backups'; fi
 if ((rc)) && [[ "${UI_FINISHED:-0}" != 1 ]]; then screen_finish error; fi
 INSTALL_WIZARD=0
 return "$rc"
}
install_flow(){
 require_root
 local os_id
 os_id=$(source /etc/os-release; printf '%s' "$ID")
 [[ "$os_id" == ubuntu || "$os_id" == debian ]] || { warn 'Нужна Ubuntu/Debian с systemd'; return 1; }
 [[ $(uname -m) == x86_64 ]] || { warn 'MTProxy требует x86_64'; return 1; }
 mkdir -p "$BASE"; chmod 700 "$BASE"
 touch "$LOG"; chmod 600 "$LOG"
 stage 0 'Проверка зависимостей и установка недостающего' dependencies || return 1
 summary_add 'Зависимости' 'проверены'
 if existing_selfsteal; then
  DOMAIN=${DOMAIN:-$(selfsteal_value SELF_STEAL_DOMAIN)}
  summary_add 'SelfSteal' 'найден; повторная установка сайта будет пропущена'
 fi
 if [[ "$(backend_type)" == containers && ! -f "$BASE/.installed" ]]; then
  info 'Продолжаю незавершённую установку, сохраняя домен и секрет.'
  touch "$LOG"; chmod 600 "$LOG"
  DOMAIN=$(active_domain); MODE=$(active_mode)
  summary_add 'Домен' "$DOMAIN"; summary_add 'Режим' "$MODE"
  stage 7 'SelfSteal и сохранённая конфигурация' resume_deployment || return 1
  stage 8 'Сборка backend и образ SelfSteal' build_deployment || return 1
  stage 9 'Проверка Caddy, запуск контейнеров и TLS' start_deployment || return 1
  stage 10 'Проверка готовности и HTTPS' verify_deployment || return 1
  touch "$BASE/.installed"
  register_commands
  write_info_file
  ok "Установка $VERSION завершена"
  webmtproxy link
  return 0
 fi
 if [[ "$(backend_type)" == containers && ! -f "$BASE/.selfsteal" ]]; then integrate_existing; return; fi
 if [[ "$(backend_type)" != none ]]; then warn 'Прокси уже установлен. Используй zlp обновить; настройки сохраняются.'; return 0; fi
 mkdir -p "$BASE"; chmod 700 "$BASE"
 touch "$LOG"; chmod 600 "$LOG"
 check_connectivity || return 1
 print_step 2 'Базовая настройка'
 info 'WEB Proxy использует HTTPS :443; SelfSteal :9443 доступен только локально.'
 while :; do
  ask DOMAIN 'Домен прокси (без https://)' "${DOMAIN:-}" || return 1
  DOMAIN=${DOMAIN,,}
  valid_domain "$DOMAIN" && break
  warn 'Некорректный домен'
 done
 summary_add 'Домен' "$DOMAIN"
 summary_add 'Порт WEB Proxy' 443
 screen_finish success
 local selected
 select_menu 'WEB-транспорт' selected 'iPhone / все платформы — https' 'Поддерживаемые клиенты — https-lanes' || return 1
 case "$selected" in 0) MODE=https;; 1) MODE=https-lanes;; esac
 summary_add 'Режим' "$MODE"
 screen_finish success
 INSTALL_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
 print_step 4 'Регистрация прокси в Telegram'
 printf '  1. Откройте @MTProxybot и отправьте /newproxy\n  2. Хост: %s:443\n  3. Секрет: %s\n' "$DOMAIN" "$INSTALL_SECRET"
 ask INSTALL_TAG 'AD_TAG от @MTProxybot: 32 hex (Enter = пропустить)' || return 1
 if [[ -n "$INSTALL_TAG" && ! "$INSTALL_TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
  warn 'AD_TAG должен содержать 32 hex символа'; return 1
 fi
 summary_add 'AD_TAG' "${INSTALL_TAG:-пропущен}"
 screen_finish "$([[ -n "$INSTALL_TAG" ]] && echo success || echo skipped)"
 print_step 5 'Telegram-бот для отправки ссылки (опционально)'
 local bot_token chat_id
 printf 'Bot Token (Enter = пропустить): ' >/dev/tty
 read -r -s bot_token </dev/tty || return 1
 printf '\n' >/dev/tty
 chat_id=
 if [[ -n "$bot_token" ]]; then
  ask chat_id 'Chat ID' || return 1
  [[ "$bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ && "$chat_id" =~ ^-?[0-9]+$ ]] || { warn 'Некорректный Bot Token или Chat ID'; return 1; }
 fi
 if [[ -n "$bot_token" ]]; then
  summary_add 'Telegram-бот' 'настроен (токен скрыт)'
  summary_add 'Chat ID' "$chat_id"
  screen_finish success
 else
  summary_add 'Telegram-бот' 'пропущен'
  screen_finish skipped
 fi
 stage 6 'Проверка портов и DNS → IPv4 сервера' check_install_network || return 1
 stage 7 'Нативная установка SelfSteal, сайт и конфигурация' write_deployment || return 1
 stage 8 'Сборка backend и образ SelfSteal' build_deployment || return 1
 stage 9 'Проверка Caddy, запуск SelfSteal и WEB Proxy' start_deployment || return 1
 stage 10 'Проверка готовности и HTTPS' verify_deployment || return 1
 touch "$BASE/.installed"
 register_commands
 write_info_file
 if [[ -n "$bot_token" ]]; then
  screen_begin 11 'Отправка ссылки в Telegram'
  if send_connection_message "$bot_token" "$chat_id"; then screen_finish success
  else screen_finish warning; warn 'Ссылка не отправлена. Прокси установлен; ссылка доступна через zlp links.'; fi
 fi
 screen_begin 12 'Готово'
 screen_finish success
 ok "ПРОСТОВПН WEB PROXY $VERSION установлен. Меню: zlp"
 webmtproxy link
}
check_install_network(){
 local port reuse=0
 if existing_selfsteal; then
  validate_existing_selfsteal || return 1
  reuse=1
  ui_status skipped 'Существующий SelfSteal будет использован повторно'
 fi
 for port in 80 443 9443; do
  if port_busy "$port"; then
   if ((reuse)) && selfsteal_owns_port "$port"; then
    ui_status skipped "Порт $port занят установленным SelfSteal — конфликт отсутствует"
   else warn "Порт $port занят другой службой. Освободи его перед установкой."; return 1; fi
  fi
 done
 check_dns
}
verify_mode(){
 local attempt domain
 domain=$(active_domain) || return 1
 for ((attempt=0;attempt<15;attempt++)); do
  if compose exec -T relay curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1 &&
     compose exec -T mtproxy sh -c 'ss -lntH sport = :2398 | grep -q .' >/dev/null 2>&1 &&
     curl -fsS --max-time 3 --resolve "$domain:443:127.0.0.1" "https://$domain/" >/dev/null 2>&1; then return 0; fi
  sleep 2
 done
 return 1
}
change_mode(){
 local previous backup
 previous=$(python3 "$APP/lib/config.py" "$BASE" mode) || return 1
 backup=$(mktemp "$BASE/config/profiles.rollback.XXXXXX") || return 1
 if ! cp "$BASE/config/profiles.json" "$backup"; then rm -f "$backup"; return 1; fi
 if ! python3 "$APP/lib/config.py" "$BASE" mode "$1"; then rm -f "$backup"; return 1; fi
 info 'Проверка запуска прокси после смены режима…'
 if compose restart relay && verify_mode; then
  rm -f "$backup"
  return 0
 fi
 warn "Прокси не прошёл проверку запуска. Возвращаю предыдущий режим: $previous"
 compose logs --tail 20 relay >&2 || true
 if ! mv -f "$backup" "$BASE/config/profiles.json"; then
  warn "Не удалось восстановить конфигурацию. Резервная копия: $backup"
  return 1
 fi
 if compose restart relay && verify_mode; then
  warn "Предыдущий режим $previous восстановлен, прокси работает. Смена отменена."
 else
  warn "Настройки режима $previous восстановлены, но прокси не прошёл повторную проверку. Проверь состояние сервисов и журналы."
 fi
 return 1
}
webmtproxy(){
 if [[ "$(backend_type)" != containers ]]; then command webmtproxy "$@"; return; fi
 local action=${1:-link}; shift || true
 case "$action" in
  mode)
   if (($#)); then change_mode "$1"; else python3 "$APP/lib/config.py" "$BASE" mode; fi;;
  link|sponsor|secret|secret-raw|rotate-secret)
   python3 "$APP/lib/config.py" "$BASE" "$action" "$@" || return 1
   if (($#)) || [[ "$action" == rotate-secret ]]; then
    if [[ "$action" == sponsor || "$action" == secret || "$action" == rotate-secret ]]; then compose up -d --force-recreate; else compose restart relay; fi
   fi;;
  qr) python3 "$APP/lib/config.py" "$BASE" link | qrencode -t UTF8;;
  *) warn 'Эта операция недоступна для контейнерной установки'; return 1;;
 esac
}

format_speed(){
 LC_NUMERIC=C awk -v bytes="$1" -v seconds="$2" 'BEGIN {
  if (seconds <= 0 || bytes < 0) { printf "—"; exit }
  rate = bytes / seconds
  if (rate >= 125000000) printf "%.1f Гбит/с", rate * 8 / 1000000000
  else if (rate >= 1000000) printf "%.1f МБ/с", rate / 1000000
  else printf "%.1f Кбит/с", rate * 8 / 1000
 }'
}
dashboard_line(){
 local chunk
 printf -v chunk "$@"
 DASH_TEXT+=$chunk
}
dashboard(){
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
   rx=$(format_speed "$((up-PREV_UP))" "$((now-PREV_TIME))")
   tx=$(format_speed "$((down-PREV_DOWN))" "$((now-PREV_TIME))")
  fi
  PREV_UP=$up; PREV_DOWN=$down; PREV_TIME=$now
 else PREV_TIME=; fi
 local problem problems=() units=()
 if [[ "$type" == containers ]]; then
  state=$(systemctl is-active docker 2>/dev/null || true)
  [[ "$state" == active ]] || problems+=("Docker — ${state:-недоступен}")
  for unit in caddy relay mtproxy; do
   local container="prostoweb-$unit-1"
   [[ "$unit" != caddy || ! -f "$BASE/.selfsteal" ]] || container=caddy-selfsteal
   state=$(timeout 2 docker inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || echo недоступен)
   case "$state" in running|'running / healthy') ;; *) problems+=("$unit — $state");; esac
  done
  [[ -n "$metrics" ]] || problems+=("WEB-релей — метрики недоступны")
 elif [[ "$type" != none ]]; then
  if [[ "$type" == webmtproxy ]]; then units=(nginx mtproxy tproxy-server tproxy-firewall)
  else units=(nginx telemt); fi
  for unit in "${units[@]}"; do
   state=$(systemctl is-active "$unit" 2>/dev/null || true)
   [[ "$state" == active ]] || problems+=("$unit — ${state:-недоступен}")
  done
 else problems+=('Прокси не установлен'); fi
 dashboard_line '  %sРежим%s %s%s%s\n\n' "$cyan" "$clear" "$green" "$mode" "$clear"
 if ((${#problems[@]}==0)); then
  dashboard_line '  %sСтатус%s %sОК%s\n' "$cyan" "$clear" "$green" "$clear"
 else
  dashboard_line '  %sСтатус%s %sНЕ ОК%s\n' "$cyan" "$clear" "$red" "$clear"
  for problem in "${problems[@]}"; do dashboard_line '    %s%s%s\n' "$red" "$problem" "$clear"; done
 fi
 dashboard_line '\n  %sПодключения%s %s%s%s\n' "$cyan" "$clear" "$green" "${users:-—}" "$clear"
 dashboard_line '  %sПриём%s %s · %sОтдача%s %s\n\n' "$cyan" "$clear" "$rx" "$cyan" "$clear" "$tx"
 if [[ "$type" == containers || "$type" == webmtproxy ]]; then
  dashboard_line '  %sСсылка%s %s%s%s\n' "$cyan" "$clear" "$green" "$(webmtproxy link 2>/dev/null || echo недоступно)" "$clear"
  dashboard_line '  %sСайт%s   %shttps://%s/%s\n' "$cyan" "$clear" "$green" "$domain" "$clear"
 fi
 printf '%s' "$DASH_TEXT"
}
menu_management(){
 local choice
 while :; do
  select_menu 'Настройки' choice 'Режим передачи' 'Спонсорский канал' 'Секрет' 'Управление сервисами' 'Сайт SelfSteal и TLS' 'Обновить скрипт' 'Назад' || return 0
  case "$choice" in
   0) if ensure_web >/dev/null; then menu_transport; else result_begin; warn 'Режим передачи недоступен'; wait_back; fi;;
   1) if ensure_web >/dev/null; then menu_sponsor; else result_begin; warn 'Спонсорский канал недоступен'; wait_back; fi;;
   2) menu_secret;;
   3) if [[ "$(backend_type)" == containers ]]; then menu_containers; else menu_services; fi;;
   4) menu_selfsteal;;
   5) result_begin; update_project || warn 'Обновление не завершено'; wait_back;;
   6) return 0;;
  esac
 done
}
menu_selfsteal(){
 local choice action
 [[ -f "$BASE/.selfsteal" ]] || { result_begin; warn 'SelfSteal ещё не объединён с этой установкой'; wait_back; return 0; }
 while :; do
  select_menu 'Сайт SelfSteal и TLS' choice 'Выбрать шаблон сайта' 'Состояние и сертификат' 'Обновить сертификат' 'Перевыпустить сертификат' 'Редактировать конфигурацию' 'Размер журналов' 'Очистить журналы' 'Инструкция SelfSteal' 'Назад' || return 0
  case "$choice" in
   0) action=template;; 1) action=status;; 2) action=renew-ssl;;
   3) action=reissue-cert;; 4) action=edit;; 5) action=logs-size;;
   6) action=clean-logs;; 7) action=guide;; 8) return 0;;
  esac
  result_begin
  BASE="$BASE" SELFSTEAL_DIR="$SELFSTEAL_DIR" bash "$APP/lib/selfsteal.sh" "$action" || warn 'Команда SelfSteal не завершена'
  wait_back
 done
}
menu_containers(){
 local choice
 while :; do
  select_menu 'Управление сервисами' choice 'Состояние' 'Перезапустить все контейнеры' 'Запустить' 'Остановить' 'Журнал' 'Назад' || return 0
  [[ "$choice" != 5 ]] || return 0
  result_begin
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
 if ! validate_release "$temp"; then
  rm -rf -- "$temp"; warn 'Обновление не прошло проверку'; return 1
 fi
 release="$BASE/app/releases/$(git -C "$temp" rev-parse HEAD)"
 if [[ ! -d "$release" ]]; then mv "$temp" "$release"; else rm -rf -- "$temp"; fi
 stamp=$(date +%Y%m%d-%H%M%S)
 if [[ "$(backend_type)" == containers ]]; then
  snapshot_deployment "$BASE/backups/$stamp" || return 1
  old_compose="$BASE/backups/$stamp/compose.yaml"
  local image
  for image in relay mtproxy; do docker tag "prostoweb-$image:local" "prostoweb-$image:rollback-$stamp" || return 1; done
  APP=$release
  if ! BASE="$BASE" SELFSTEAL_DIR="$SELFSTEAL_DIR" bash -c 'source "$1/prstaproxy.sh"; resume_deployment' _ "$release" ||
     ! build_deployment || ! start_deployment --force-recreate || ! verify_deployment; then
   for image in relay mtproxy; do docker tag "prostoweb-$image:rollback-$stamp" "prostoweb-$image:local"; done
   restore_deployment "$BASE/backups/$stamp" || rolled=1
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
 if [[ "${RESULT_OPEN:-0}" == 1 ]]; then wait_back; fi
 exec bash "$release/prstaproxy.sh"
}
validate_release(){
 local directory=$1 file
 for file in prstaproxy.sh install.sh lib/core.sh lib/interface.sh lib/ui.sh lib/selfsteal_existing.sh lib/selfsteal.sh vendor/selfsteal.sh docker/mtproxy-entrypoint.sh; do
  bash -n "$directory/$file" || return 1
 done
 python3 -m py_compile "$directory/lib/config.py" "$directory/lib/selfsteal_config.py" "$directory/lib/selfsteal_existing.py"
}
