#!/usr/bin/env bash
set -Eeuo pipefail
ZLP_APP=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ZLP_BASE=${BASE:-/opt/prostoweb}
ZLP_SELFSTEAL_DIR=${SELFSTEAL_DIR:-/opt/caddy}
[[ "${1:-}" != @ ]] || shift
zlp_args=("$@")
zlp_action=${1:-menu}
zlp_internal=false
case "$zlp_action" in
 --zlp-prepare) zlp_internal=true; zlp_domain=$2; zlp_template=${3:-}; set -- --caddy;;
 --zlp-template) zlp_internal=true; zlp_template=${2:-random}; set -- --caddy;;
 --zlp-validate|--zlp-image) zlp_internal=true; set -- --caddy;;
 --help|-h|help) set -- --caddy help;;
 '') set -- --caddy menu;;
esac
if [[ -r "$ZLP_BASE/public-ip" ]]; then ZLP_NODE_IP=$(cat "$ZLP_BASE/public-ip"); fi
# Keep the vendored source intact; skip only its final command dispatcher.
source <(sed -e '/^# Main execution/,$d' \
 -e 's/^NODE_IP=$(get_server_ip)$/NODE_IP=${ZLP_NODE_IP:-$(get_server_ip)}/' \
 "$ZLP_APP/vendor/selfsteal.sh")
eval "$(declare -f install_command | sed '1s/install_command/native_install_command/')"
if [[ "$WEB_SERVER" != caddy && -f "$ZLP_BASE/.selfsteal" ]]; then
 log_error 'Общая установка использует Caddy; переключение на Nginx требует отдельной миграции.'
 exit 1
fi
APP_DIR=$ZLP_SELFSTEAL_DIR
HTML_DIR="$APP_DIR/html"
CONTAINER_NAME=caddy-selfsteal
WEB_SERVER=caddy
VOLUME_PREFIX=caddy
# Native validation runs a temporary container; include the managed import.
docker(){
 if [[ "${ZLP_NATIVE_INSTALL:-0}" == 1 && "${1:-}" == compose && "${2:-}" == up ]]; then
  log_info 'Запуск Caddy отложен до запуска общего WEB Proxy стека'
  return 0
 fi
 if [[ -f "$ZLP_BASE/selfsteal-existing.json" && "${1:-}" == run ]]; then
  local original_image argument
  local adjusted=()
  original_image=$(python3 "$ZLP_APP/lib/selfsteal_existing.py" "$ZLP_BASE" --image) || return 1
  for argument in "$@"; do
   [[ "$argument" != "caddy:${CADDY_VERSION}" ]] || argument=$original_image
   adjusted+=("$argument")
  done
  set -- "${adjusted[@]}"
 fi
 if [[ "${1:-}" == run && " $* " == *' caddy validate '* && -f "$APP_DIR/zlp.Caddyfile" ]]; then
  shift
  command docker run -v "$APP_DIR/zlp.Caddyfile:/etc/caddy/zlp.Caddyfile:ro" "$@"
 else command docker "$@"; fi
}
eval "$(declare -f get_caddy_data_volume | sed '1s/get_caddy_data_volume/native_get_caddy_data_volume/')"
get_caddy_data_volume(){
 local volume
 if volume=$(native_get_caddy_data_volume); then printf '%s\n' "$volume"; return; fi
 command docker volume inspect prostoweb_caddy-data >/dev/null 2>&1 && printf '%s\n' prostoweb_caddy-data
}
# Both entry points share the same project, configuration and update lifecycle.
main_menu(){ exec bash "$ZLP_APP/prstaproxy.sh" --selfsteal; }
install_command(){ exec bash "$ZLP_APP/prstaproxy.sh" --install; }
update_command(){ exec bash "$ZLP_APP/prstaproxy.sh" обновить; }
template_command(){ exec bash "$ZLP_APP/prstaproxy.sh" --templates; }
check_for_updates_silent(){ :; }
# Native screens stay inside the result block drawn by the parent menu.
clear(){ :; }
install_management_script(){
 [[ "${ZLP_NATIVE_INSTALL:-0}" != 1 ]] || return 0
 bash "$ZLP_APP/prstaproxy.sh" --install-menu
}
maybe_restart_webserver(){
 # Caddy's file_server sees template changes immediately; no relay restart needed.
 log_success 'Сайт SelfSteal обновлён; WEB-релей использует тот же сайт.'
}
if [[ "$zlp_internal" == true ]]; then
 case "$zlp_action" in
  --zlp-prepare)
   create_dir_safe "$APP_DIR"
   create_dir_safe "$HTML_DIR"
   create_dir_safe "$APP_DIR/logs"
   if [[ ! -f "$APP_DIR/Caddyfile" && ! -s "$HTML_DIR/index.html" ]]; then
    # Run the original install workflow with its own random template selection,
    # download fallbacks and randomization, without a second interactive wizard.
    ZLP_NATIVE_INSTALL=1
    touch "$ZLP_BASE/.selfsteal-preparing"
    FORCE_MODE=true; FORCE_DOMAIN=$zlp_domain; FORCE_PORT=9443
    FORCE_TEMPLATE=$zlp_template
    native_install_command || exit $?
    exit 0
   fi
   if [[ ! -f "$APP_DIR/Caddyfile" ]]; then create_caddy_config "$zlp_domain" 9443; fi
   if [[ ! -s "$HTML_DIR/index.html" ]]; then
    template=${zlp_template:-$((RANDOM%11+1))}
    if ! download_template "$template"; then create_default_html; fi
   fi
   ;;
  --zlp-validate) validate_caddyfile;;
  --zlp-template)
   [[ "$zlp_template" != random ]] || zlp_template=$((RANDOM % 11 + 1))
   [[ -n "${TEMPLATE_FOLDERS[$zlp_template]:-}" ]] || { log_error 'Неизвестный шаблон'; exit 1; }
   download_template "$zlp_template" || exit $?
   maybe_restart_webserver
   ;;
  --zlp-image) ensure_runtime_image;;
 esac
 exit 0
fi
case "$COMMAND" in
 install) install_command;;
 up) up_command;; down) down_command;; restart) restart_command;;
 status) status_command;; logs) logs_command;;
 logs-size) logs_size_command;; clean-logs) clean_logs_command;;
 edit) edit_command;; template) template_command;;
 renew-ssl) renew_ssl_command;; reissue-cert|reissue|recert) reissue_cert_command;;
 guide) guide_command;; help) show_help;;
 update|check-update) update_command;; menu|'') main_menu;;
 uninstall)
  # Native uninstall would leave the shared proxy without its Caddy/site.
  check_running_as_root
  read -r -p 'Удалить общую установку WEB Proxy и SelfSteal? Данные сохранятся. [y/N]: ' answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
   (cd "$APP_DIR" && docker compose down)
   rm -f "$ZLP_BASE/.installed"
   log_success 'Контейнеры удалены. Конфигурация, сайт и volumes сохранены; selfsteal install восстановит установку.'
  fi;;
 *) log_error "Неизвестная команда: $COMMAND"; exit 1;;
esac
