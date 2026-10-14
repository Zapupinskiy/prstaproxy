#!/usr/bin/env bash
set -Eeuo pipefail
# ПРОСТОВПН WEB PROXY: container installer and legacy service management.
DOMAIN=${DOMAIN:-}; EMAIL=""; MODE=${MODE:-https}; TAG=""; BASE=${BASE:-/opt/prostoweb}
RELAY_PORT=""; ADMIN_PORT=""
NCONF=/etc/nginx/sites-available/prostoweb; NLINK=/etc/nginx/sites-enabled/prostoweb
LOG=${LOG:-/var/log/prostoweb-install.log}
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


backend_type(){
 if [[ -f "$BASE/compose.yaml" ]]; then echo containers
 elif [[ -f /etc/tproxy-server/profiles.json && -f /etc/tproxy-server/config.json ]]; then echo webmtproxy
 elif [[ -f /etc/telemt/telemt.toml ]]; then echo telemt
 else echo none; fi
}
ensure_web(){ [[ "$(backend_type)" == webmtproxy || "$(backend_type)" == containers ]] || { warn 'Эта команда доступна только для WebMTProxy. Установленный Telemt не изменён.'; return 1; }; }
active_domain(){
 if [[ "$(backend_type)" == containers ]]; then python3 "$APP/lib/config.py" "$BASE" domain
 elif [[ "$(backend_type)" == webmtproxy ]]; then
  python3 -c 'import json;print(json.load(open("/etc/tproxy-server/config.json")).get("public_hostname","не задан"))' 2>/dev/null || echo неизвестно
 elif [[ "$(backend_type)" == telemt ]]; then sed -n 's/^host = "\([^"]*\)"/\1/p' /etc/telemt/telemt.toml | head -1
 else echo неизвестно; fi
}
active_mode(){
 if [[ "$(backend_type)" == containers ]]; then python3 "$APP/lib/config.py" "$BASE" mode
 elif [[ "$(backend_type)" == webmtproxy ]]; then webmtproxy mode 2>/dev/null || echo неизвестно
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
  [[ "$choice" != 5 ]] || return 0
  result_begin
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
  [[ "$choice" != 4 ]] || return 0
  result_begin
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
        print('Текущий секрет:', secret[2:] if len(secret) == 34 and secret.startswith('dd') else secret)
except (OSError, ValueError, KeyError, TypeError) as error:
    print('Ошибка чтения секрета:', error, file=sys.stderr)
    sys.exit(1)
PYSECRET
 warn 'Не отправляй секрет посторонним. Эта команда только показывает его, ничего не изменяя.'
}

show_modes(){
 printf '\n  iPhone: https\n  Остальные устройства: https-lanes (нужна поддержка клиентом)\n'
}

menu_header(){
 printf '%s╔═════════════════════╗%s\n' "$cyan" "$clear"
 printf '%s║%s %sПРОСТОВПН WEB PROXY%s %s║%s\n' "$cyan" "$clear" "$green" "$clear" "$cyan" "$clear"
 printf '%s╚═════════════════════╝%s\n\n' "$cyan" "$clear"
}
select_menu(){
 local title=$1 outvar=$2; shift 2
 local items=("$@") index=0 key rest n=${#items[@]} i
 [[ -t 0 && -t 1 && -r /dev/tty ]] || { warn 'Требуется интерактивный терминал для меню.'; return 1; }
 RESULT_OPEN=0
 dashboard >/dev/null
 while :; do
  printf '\033[2J\033[H' > /dev/tty
  menu_header > /dev/tty
  printf '%s' "$DASH_TEXT" > /dev/tty
  ui_separator > /dev/tty
  printf "\n  %s\n\n" "$title" > /dev/tty
  for ((i=0;i<n;i++)); do
   if ((i==index)); then printf '%s  ❯ %s%s\n' "$green" "${items[i]}" "$clear" > /dev/tty
   else printf '    %s\n' "${items[i]}" > /dev/tty; fi
  done
  printf '\n' > /dev/tty
  key=""
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
ui_separator(){ printf '\n%s──────────────────────────────────────────────────────%s\n' "$red" "$clear"; }
result_begin(){
 printf '\033[2J\033[H'
 menu_header
 printf '%s' "${DASH_TEXT:-}"
 ui_separator
 printf '\n'
 RESULT_OPEN=1
}
result_end(){
 if [[ "${RESULT_OPEN:-0}" == 1 ]]; then ui_separator; RESULT_OPEN=0; fi
}
wait_back(){ result_end; printf '\nНажми Enter для возврата...' >/dev/tty; read -r _ </dev/tty || true; }
choose_transport(){
 local outvar=$1 title=$2 item
 local choices=(
  'HTTPS — iPhone / все платформы · максимальная совместимость'
  'HTTPS-Lanes — ПК / поддерживаемые клиенты · параллельный HTTPS'
  'Назад'
 )
 select_menu "$title" item "${choices[@]}" || return 1
 case "$item" in
  0) printf -v "$outvar" '%s' 1;; 1) printf -v "$outvar" '%s' 2;;
  *) return 1;;
 esac
}

menu_access(){
 local choice
 while :; do
  select_menu 'ПРОСТО WEB PROXY · Доступ' choice \
   'Показать ссылку' 'Показать QR-код' 'Показать действующий секрет' 'Сменить секрет' 'Назад' || return 0
  [[ "$choice" != 4 ]] || return 0
  result_begin
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

menu_secret(){
 local choice secret
 while :; do
  select_menu 'Секрет' choice 'Показать текущий секрет' 'Сгенерировать новый секрет' 'Ввести свой секрет' 'Показать ссылку подключения' 'Показать QR-код' 'Назад' || return 0
  [[ "$choice" != 5 ]] || return 0
  result_begin
  case "$choice" in
   0) if [[ "$(backend_type)" == containers ]]; then webmtproxy secret-raw || warn 'Не удалось получить секрет'; else show_current_secret || true; fi;;
   1) if yesno 'Сгенерировать новый секрет? Старые ссылки перестанут работать, соединения прервутся'; then
       if webmtproxy rotate-secret; then ok 'Секрет обновлён'; webmtproxy link; else warn 'Не удалось применить новый секрет; проверь состояние сервисов'; fi
      else info 'Отменено'; fi;;
   2) if [[ "$(backend_type)" != containers ]]; then
       warn 'Ввод своего секрета доступен для контейнерной установки'
      else
       ask secret 'Секрет: 32 hex символа или dd + 32 hex (Enter — отмена)' ''
       secret=${secret,,}
       if [[ -z "$secret" ]]; then info 'Отменено'
       elif [[ "$secret" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; then
        if yesno 'Установить этот секрет? Старые ссылки перестанут работать, соединения прервутся'; then
         if webmtproxy secret "$secret"; then ok 'Секрет обновлён'; webmtproxy link; else warn 'Не удалось применить новый секрет; проверь состояние сервисов'; fi
        else info 'Отменено'; fi
       else warn 'Некорректный секрет: нужны 32 hex символа или dd + 32 hex'; fi
      fi;;
   3) webmtproxy link || warn 'Не удалось получить ссылку';;
   4) if command -v qrencode >/dev/null; then webmtproxy qr || true; else warn 'Установи qrencode для отображения QR-кода'; fi;;
  esac
  wait_back
 done
}

menu_sponsor(){
 local choice tag
 while :; do
  select_menu 'Спонсорский канал' choice 'Показать установленный тег' 'Установить тег от @MTProxybot' 'Отключить тег' 'Назад' || return 0
  [[ "$choice" != 3 ]] || return 0
  result_begin
  case "$choice" in
   0) webmtproxy sponsor || warn 'Не удалось получить тег';;
   1) ask tag 'Тег от @MTProxybot (32 hex)' ''
      if [[ "$tag" =~ ^[0-9a-fA-F]{32}$ ]]; then
       webmtproxy sponsor "$tag" && ok 'Спонсорский тег установлен' || warn 'Не удалось установить тег'
      elif [[ -n "$tag" ]]; then warn 'Тег должен содержать 32 hex символа'; fi;;
   2) if yesno 'Отключить спонсорский тег?'; then
       webmtproxy sponsor off && ok 'Спонсорский тег отключён' || warn 'Не удалось отключить тег'
      fi;;
  esac
  wait_back
 done
}

menu_transport(){
 local choice mode
 while :; do
  select_menu 'ПРОСТО WEB PROXY · Транспорт' choice \
   'Показать текущий режим' 'Изменить режим (iPhone / быстрый)' 'Подсказка по режимам' 'Назад' || return 0
  [[ "$choice" != 3 ]] || return 0
  result_begin
  case "$choice" in
   0) webmtproxy mode || true;;
   1) if choose_transport mode 'Выбери новый WEB-транспорт'; then
        result_begin
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
 [[ $EUID -eq 0 ]] || die 'Нужен root: sudo zlp'
 local choice
 while :; do
  select_menu 'Главное меню' choice 'Установка прокси' 'Обновить' 'Настройки' 'Выход' || break
  case "$choice" in
   0) result_begin; install_new || warn 'Установка не завершена'; wait_back;;
   1) continue;;
   2) menu_management;;
   3) break;;
  esac
 done
 result_begin
 ok 'Выход из ПРОСТОВПН WEB PROXY'
 result_end
}
APP=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$APP/lib/core.sh"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
 case "${1:-}" in
  обновить|update|--update) update_project;;
  --install) install_new;;
  --install-menu|--update-menu) register_commands;;
  --status) dashboard;;
  --selfsteal) require_root; menu_selfsteal;;
  --version) printf '%s\n' "$VERSION";;
  '')
   require_root
   if [[ "$(backend_type)" == containers && ! -f "$BASE/.selfsteal" && -f "$BASE/.installed" ]]; then
    integrate_existing || warn 'SelfSteal не интегрирован. Прежняя конфигурация восстановлена.'
   fi
   register_commands; main_menu;;
  *) die 'Команды: zlp | zlp обновить | zlp --install | zlp --status | zlp --version';;
 esac
fi
