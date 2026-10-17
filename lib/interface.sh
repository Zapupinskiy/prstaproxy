#!/usr/bin/env bash
# Terminal workflow adapted from andrchq/mt_proxy 2.1.0; deployment stays WEB Proxy.
source "$APP/lib/ui.sh"
print_step(){ screen_begin "$1" "$2"; }
menu_header(){ print_header 'ПРОСТОВПН WEB PROXY'; }
terminal_animated(){ [[ -t 1 && "${TERM:-dumb}" != dumb ]]; }
show_log_tail(){
 # Upstream programs keep their original logs; terminal details use our neutral palette.
 tail -n "$1" "$2" | sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g'
}
run_live_log(){
 local logfile pid rc=0 frame=0 start=$SECONDS frames='|/-\\'
 logfile=$(mktemp)
 ("$@" 2>&1 | tee -a "$LOG" >"$logfile") & pid=$!
 # Never redraw a block of log lines: wrapping/terminal resizing corrupts cursor offsets.
 while kill -0 "$pid" 2>/dev/null; do
  if terminal_animated; then
   printf '\r\033[K%s%s Выполняется · %02d:%02d%s' "$UI_LOADER" "${frames:frame%4:1}" "$(((SECONDS-start)/60))" "$(((SECONDS-start)%60))" "$UI_RESET"
  fi
  frame=$((frame+1)); sleep 0.2
 done
 wait "$pid" || rc=$?
 if terminal_animated; then printf '\r\033[K'; fi
 if ((rc)); then
  ui_status error "Ошибка операции (код $rc)"
  show_log_tail 15 "$logfile"
  warn "Полный журнал: $LOG"
 else
  ui_status success "Выполнено · $((SECONDS-start)) с"
  # Details appear once, not once per animation frame.
  show_log_tail 6 "$logfile"
 fi
 rm -f -- "$logfile"
 return "$rc"
}
check_connectivity(){
 ui_status running 'Проверка доступности сети: Telegram и сервисы РФ'
 local telegram_ok=0 ru_ok=0 service
 curl -sS --connect-timeout 5 --max-time 8 -o /dev/null https://api.telegram.org && telegram_ok=1
 for service in https://ya.ru https://mail.ru https://vk.com https://ok.ru https://www.rambler.ru; do
  if curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null "$service"; then ru_ok=$((ru_ok+1)); fi
 done
 printf 'Telegram: %s, сервисы РФ: %s/5\n' "$telegram_ok" "$ru_ok"
 if ((telegram_ok==0 || ru_ok<3)); then
  warn 'Обнаружены проблемы с сетью. Проверка не гарантирует доступность прокси из РФ.'
  yesno 'Продолжить установку при сетевых ограничениях?' || { ui_status error 'Проверка сети отменена'; return 1; }
  ui_status warning 'Сетевые ограничения: продолжаем по вашему выбору'; return 0
 fi
 ui_status success 'Проверка сети завершена'
}
menu_read_key(){
 local key rest
 MENU_KEY=
 IFS= read -r -s -n1 key </dev/tty || return 1
 case "$key" in
  '') MENU_KEY=ENTER;;
  $'\033')
   rest=; IFS= read -r -s -n1 -t 0.15 rest </dev/tty || true
   if [[ "$rest" == '[' || "$rest" == O ]]; then
    IFS= read -r -s -n1 -t 0.15 rest </dev/tty || true
    case "$rest" in A) MENU_KEY=UP;; B) MENU_KEY=DOWN;; esac
   else MENU_KEY=BACK; fi;;
  k|K) MENU_KEY=UP;; j|J) MENU_KEY=DOWN;;
 esac
}
render_menu_items(){
 local selected=$1 item_index=0 item color prefix
 shift
 for item in "$@"; do
  color=$UI_RESET; prefix='  '
  [[ "$item" != Назад ]] || color=$'\033[90m'
  if ((item_index==selected)); then
   prefix='❯ '
   [[ "$item" == Назад ]] || color=$UI_TITLE
  fi
  printf '  %s%s%s%s\n' "$color" "$prefix" "$item" "$UI_RESET"
  item_index=$((item_index+1))
 done
}
select_menu(){
 local title=$1 outvar=$2 selected_index=0 count; shift 2
 local items=("$@")
 RESULT_OPEN=0
 if [[ "${INSTALL_WIZARD:-0}" != 1 ]]; then dashboard >/dev/null; fi
 count=${#items[@]}
 while :; do
  if [[ "${INSTALL_WIZARD:-0}" == 1 ]]; then
   screen_begin "${UI_STAGE_ID:-2}" "$title"
  else
   terminal_clear; menu_header
   printf '%s\n\n%s%s%s\n\n' "$DASH_TEXT" "$UI_TITLE" "$title" "$UI_RESET"
  fi
  render_menu_items "$selected_index" "${items[@]}"
  printf '\n  ↑/↓ — выбор · Enter — открыть · Esc — назад\n'
  menu_read_key || return 1
  case "$MENU_KEY" in
   UP) selected_index=$(((selected_index+count-1)%count));;
   DOWN) selected_index=$(((selected_index+1)%count));;
   ENTER) printf -v "$outvar" '%s' "$selected_index"; return 0;;
   BACK) return 2;;
  esac
 done
}
wait_back(){
 result_end
 printf '\n  \033[90m❯ Назад\033[0m\n'
 while menu_read_key; do
  [[ "$MENU_KEY" != ENTER && "$MENU_KEY" != BACK ]] || return 0
 done
}
stage_navigation(){
 local navigation
 [[ "${INSTALL_WIZARD:-0}" == 1 && -t 1 && -r /dev/tty ]] || return 0
 select_menu "$2" navigation 'Продолжить' 'Назад' || return 2
 [[ "$navigation" == 0 ]] || return 2
}
require_installation(){ [[ "$(backend_type)" != none ]] || { warn 'Прокси ещё не установлен'; return 1; }; }
service_action(){
 local action=$1
 require_installation || return 1
 if [[ "$(backend_type)" == containers ]]; then
  case "$action" in start) compose up -d;; stop) compose stop;; restart) compose restart;; logs) compose logs --tail 100 -f;; esac
 else
  local units=(nginx mtproxy tproxy-server tproxy-firewall)
  [[ "$(backend_type)" != telemt ]] || units=(nginx telemt)
  if [[ "$action" == logs ]]; then journalctl -u "${units[0]}" -n 100 -f
  else systemctl "$action" "${units[@]}"; fi
 fi
}
backup_project(){
 require_root; require_installation || return 1
 local dest="$BASE/backups/$(date +%Y%m%d-%H%M%S)-$$"
 mkdir -p "$BASE/backups"
 if [[ "$(backend_type)" == containers ]]; then
  snapshot_deployment "$dest" || return 1
  # snapshot_deployment includes the site and native SelfSteal settings.
  info 'Docker volumes с сертификатами сохраняются отдельно средствами Docker.'
 else backup; return; fi
 ok "Резервная копия: $dest"
}
write_info_file(){
 local destination="$BASE/info.txt"
 umask 077
 {
  printf 'ПРОСТОВПН WEB PROXY %s\nДата: %s\n' "$VERSION" "$(date -Is)"
  printf 'Хост прокси: %s\nПорт: 443\nРежим: %s\n' "$(active_domain)" "$(active_mode)"
  printf 'Ссылка: %s\n' "$(webmtproxy link)"
  printf 'Команда управления: zlp\n'
 } > "$destination"
 chmod 600 "$destination"
}
send_connection_message(){
 local token=$1 chat=$2 response
 response=$(curl -fsS --connect-timeout 5 --max-time 20 "https://api.telegram.org/bot$token/sendMessage" \
  --data-urlencode "chat_id=$chat" --data-urlencode "text=ПРОСТОВПН WEB PROXY: $(webmtproxy link)") || return 1
 python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") else 1)' <<< "$response"
}
uninstall_project(){
 require_root; require_installation || return 1
 [[ "$(backend_type)" == containers ]] || { warn 'Для прежней systemd-установки используйте её штатный деинсталлятор'; return 1; }
 print_header 'УДАЛЕНИЕ ПРОСТОВПН WEB PROXY'
 local confirm purge
 warn 'Будут удалены контейнеры. Далее можно выбрать удаление данных.'
 ask confirm 'Подтвердите удаление: YES (Enter = отмена)'
 [[ "$confirm" == YES ]] || return 0
 ask purge 'Удалить конфигурацию, сайт и TLS volumes? DELETE (Enter = сохранить)' || return 1
 if [[ "$purge" == DELETE ]]; then
  [[ "$BASE" == /opt/prostoweb && "$SELFSTEAL_DIR" == /opt/caddy && ! -L "$BASE" && ! -L "$SELFSTEAL_DIR" ]] || {
   warn 'Удаление данных разрешено только в штатных каталогах'; return 1;
  }
  compose down -v || return 1
  rm -rf -- /opt/prostoweb/config /opt/caddy/html
  rm -f -- /opt/prostoweb/compose.yaml /opt/prostoweb/Caddyfile /opt/prostoweb/.installed /opt/prostoweb/.selfsteal /opt/prostoweb/public-ip /opt/prostoweb/info.txt
  rm -f -- /opt/prostoweb/selfsteal-existing.json /opt/prostoweb/.selfsteal-handoff /opt/prostoweb/.selfsteal-preparing
  rm -f -- /opt/caddy/Caddyfile /opt/caddy/zlp.Caddyfile /opt/caddy/.env /opt/caddy/docker-compose.yml
  ok 'Контейнеры, настройки, сайт и Compose volumes удалены. Установщик и резервные копии сохранены.'
 else
  compose down || return 1
  rm -f -- "$BASE/.installed"
  ok 'Контейнеры удалены. zlp install восстановит установку с сохранённым секретом.'
 fi
}
show_manage_help(){
 printf '%s\n' 'zlp — дашборд и меню' \
  'zlp install | status | start | stop | restart | logs | links | stats' \
  'zlp mode [https|https-lanes] | ad-tag [32 hex|off] | secret | qr' \
  'zlp tls-domain | backup | update | version | uninstall | help'
}
dispatch_command(){
 local action=$1; shift
 case "$action" in
  version|--version) printf '%s\n' "$VERSION";;
  help|-h|--help) show_manage_help;;
  *)
   require_root
   case "$action" in
    install|--install) install_new;;
    обновить|update|upgrade|--update) update_project;;
    status|dashboard|--status) menu_header; dashboard; show_manage_help;;
    start|stop|restart|logs) service_action "$action";;
    links) require_installation && webmtproxy link;;
    stats) require_installation && dashboard;;
    mode) require_installation && webmtproxy mode "$@";;
    ad-tag|adtag|tag) require_installation && webmtproxy sponsor "$@";;
    secret) require_installation && menu_secret;;
    qr) require_installation && webmtproxy qr;;
    tls-domain|set-tls) require_installation && menu_selfsteal;;
    --templates) require_installation && menu_templates;;
    backup) backup_project;;
    uninstall) uninstall_project;;
    *) warn "Неизвестная команда: $action"; show_manage_help; return 1;;
   esac;;
 esac
}
menu_installation(){
 local choice
 while :; do
  select_menu 'Установка' choice 'Установить / продолжить установку' 'Обновить проект' 'Резервная копия' 'Удалить прокси' 'Назад' || return 0
  [[ "$choice" != 4 ]] || return 0
  result_begin
  case "$choice" in
   0) install_new;; 1) update_project;; 2) backup_project;; 3) uninstall_project;;
  esac || warn 'Операция не завершена'
  wait_back
 done
}
menu_templates(){
 local choice template
 local labels=('Случайный шаблон' '10gag' 'Convertit' 'Converter' 'Downloader' 'FileCloud' 'Games-site' 'ModManager' 'SpeedTest' 'YouTube' '503 Error v1' '503 Error v2' 'Назад')
 while :; do
  select_menu 'Шаблоны SelfSteal' choice "${labels[@]}" || return 0
  [[ "$choice" != 12 ]] || return 0
  template=$choice; [[ "$choice" != 0 ]] || template=random
  result_begin
  BASE="$BASE" SELFSTEAL_DIR="$SELFSTEAL_DIR" bash "$APP/lib/selfsteal.sh" --zlp-template "$template" || warn 'Не удалось загрузить шаблон'
  wait_back
 done
}
menu_access(){
 local choice
 while :; do
  select_menu 'Доступ и секрет' choice 'Ссылка подключения' 'QR-код' 'Сменить / посмотреть секрет' 'Назад' || return 0
  case "$choice" in
   0) result_begin; webmtproxy link || true; wait_back;;
   1) result_begin; webmtproxy qr || true; wait_back;;
   2) menu_secret;; 3) return 0;;
  esac
 done
}
menu_management(){
 local choice
 while :; do
  select_menu 'Настройки' choice 'Доступ и секрет' 'Транспорт и спонсор' 'Сервисы и диагностика' 'Сайт SelfSteal и TLS' 'О проекте' 'Назад' || return 0
  case "$choice" in
   0) menu_access;; 1) menu_connection;; 2) menu_system;; 3) menu_selfsteal;;
   4) result_begin; dispatch_command version; wait_back;; 5) return 0;;
  esac
 done
}
menu_connection(){
 local choice
 while :; do
  select_menu 'Транспорт и спонсор' choice 'Режим передачи' 'Спонсорский тег' 'Назад' || return 0
  case "$choice" in 0) menu_transport;; 1) menu_sponsor;; 2) return 0;; esac
 done
}
menu_system(){
 local choice
 while :; do
  select_menu 'Сервисы и диагностика' choice 'Управление сервисами' 'Статистика' 'Диагностика' 'Назад' || return 0
  case "$choice" in
   0) if [[ "$(backend_type)" == containers ]]; then menu_containers; else menu_services; fi;;
   1) result_begin; dashboard; wait_back;;
   2) result_begin; if [[ "$(backend_type)" == containers ]]; then compose ps; compose logs --tail 40; else menu_diag; fi; wait_back;;
   3) return 0;;
  esac
 done
}
main_menu(){
 require_root
 local choice
 while :; do
  select_menu 'Главное меню' choice 'Установка' 'Обновить (дашборд)' 'Настройки' 'Выход' || return 0
  case "$choice" in
   0) menu_installation;; 1) continue;; 2) menu_management;; 3) return 0;;
  esac
 done
}
