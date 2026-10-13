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
 --zlp-validate|--zlp-image) zlp_internal=true; set -- --caddy;;
 --help|-h|help) set -- --caddy help;;
 '') set -- --caddy menu;;
esac
if [[ -r "$ZLP_BASE/public-ip" ]]; then ZLP_NODE_IP=$(cat "$ZLP_BASE/public-ip"); fi
# Keep the vendored source intact; skip only its final command dispatcher.
source <(sed -e '/^# Main execution/,$d' \
 -e 's/^NODE_IP=$(get_server_ip)$/NODE_IP=${ZLP_NODE_IP:-$(get_server_ip)}/' \
 "$ZLP_APP/vendor/selfsteal.sh")
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
check_for_updates_silent(){ :; }
# Native screens stay inside the result block drawn by the parent menu.
clear(){ :; }
install_management_script(){ bash "$ZLP_APP/prstaproxy.sh" --install-menu; }
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
   if [[ ! -f "$APP_DIR/Caddyfile" ]]; then create_caddy_config "$zlp_domain" 9443; fi
   if [[ ! -s "$HTML_DIR/index.html" ]]; then
    template=${zlp_template:-$((RANDOM%11+1))}
    if ! download_template "$template"; then create_default_html; fi
   fi
   ;;
  --zlp-validate) validate_caddyfile;;
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
