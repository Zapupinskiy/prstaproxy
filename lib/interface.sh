#!/usr/bin/env bash
# Terminal workflow adapted from andrchq/mt_proxy 2.1.0; deployment stays WEB Proxy.
source "$APP/lib/ui.sh"
print_step(){ screen_begin "$1" "$2"; }
menu_header(){ print_header 'ПРОСТОВПН WEB PROXY'; }
terminal_animated(){ [[ -t 1 && "${TERM:-dumb}" != dumb ]]; }
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
  tail -n 15 "$logfile"
  warn "Полный журнал: $LOG"
 else
  ui_status success "Выполнено · $((SECONDS-start)) с"
  # Details appear once, not once per animation frame.
  tail -n 6 "$logfile"
 fi
 rm -f -- "$logfile"
 return "$rc"
}
check_connectivity(){
 ui_status running 'Проверка доступности сети: Telegram и сервисы РФ'
 local telegram_ok=0 ru_ok=0 service confirm
 curl -sS --connect-timeout 5 --max-time 8 -o /dev/null https://api.telegram.org && telegram_ok=1
 for service in https://ya.ru https://mail.ru https://vk.com https://ok.ru https://www.rambler.ru; do
  if curl -fsS --connect-timeout 5 --max-time 8 -o /dev/null "$service"; then ru_ok=$((ru_ok+1)); fi
 done
 printf 'Telegram: %s, сервисы РФ: %s/5\n' "$telegram_ok" "$ru_ok"
 if ((telegram_ok==0 || ru_ok<3)); then
  warn 'Обнаружены проблемы с сетью. Проверка не гарантирует доступность прокси из РФ.'
  ask confirm 'Продолжить установку? (yes/no)' no || { ui_status error 'Проверка сети отменена'; return 1; }
  [[ "$confirm" == yes ]] || { ui_status error 'Проверка сети отменена'; return 1; }
  ui_status warning 'Сетевые ограничения: продолжаем по вашему выбору'; return 0
 fi
 ui_status success 'Проверка сети завершена'
}
# Numeric choices follow the reference's command dashboard; existing submenus reuse this selector.
select_menu(){
 local title=$1 outvar=$2 answer i; shift 2
 local items=("$@")
 RESULT_OPEN=0
 if [[ "${INSTALL_WIZARD:-0}" == 1 ]]; then
  printf '\n%s%s%s\n' "$UI_TITLE" "$title" "$UI_RESET"
 else
  dashboard >/dev/null
  terminal_clear; menu_header
  printf '%s\n\n%s\n' "$DASH_TEXT" "$title"
 fi
 for ((i=0;i<${#items[@]};i++)); do printf '  %s. %s\n' "$((i+1))" "${items[i]}"; done
 while :; do
  ask answer 'Выберите пункт' || return 1
  if [[ "$answer" =~ ^[0-9]{1,2}$ ]] && ((10#$answer>=1 && 10#$answer<=${#items[@]})); then
   printf -v "$outvar" '%s' "$((10#$answer-1))"; return 0
  fi
  warn 'Введите номер пункта меню'
 done
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
  rm -f -- /opt/prostoweb/selfsteal-existing.json /opt/prostoweb/.selfsteal-handoff
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
    backup) backup_project;;
    uninstall) uninstall_project;;
    *) warn "Неизвестная команда: $action"; show_manage_help; return 1;;
   esac;;
 esac
}
main_menu(){
 require_root
 local choice
 while :; do
  select_menu 'Управление WEB Proxy' choice 'Установка прокси' 'Состояние / обновить дашборд' 'Запустить' 'Остановить' 'Перезапустить' 'Журнал' 'Ссылка подключения' 'Статистика' 'Сайт и TLS' 'Спонсорский тег' 'Резервная копия' 'Обновить проект' 'Версия' 'Удалить прокси' 'Настройки WEB Proxy' 'Выход' || return 1
  case "$choice" in
   15) return 0;;
   14) menu_management; continue;;
  esac
  result_begin
  case "$choice" in
   0) install_new;; 1) dashboard;; 2) service_action start;; 3) service_action stop;;
   4) service_action restart;; 5) service_action logs;; 6) webmtproxy link;; 7) dashboard;;
   8) menu_selfsteal;; 9) menu_sponsor;; 10) backup_project;; 11) update_project;;
   12) dispatch_command version;; 13) uninstall_project;;
  esac || warn 'Операция не завершена'
  wait_back
 done
}
