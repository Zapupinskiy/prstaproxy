#!/usr/bin/env bash
# Reuse a native SelfSteal Caddy installation without reinstalling its site/TLS data.
existing_selfsteal(){
 [[ ! -f "$BASE/.selfsteal" && -f "$SELFSTEAL_DIR/docker-compose.yml" &&
    -f "$SELFSTEAL_DIR/.env" && -f "$SELFSTEAL_DIR/Caddyfile" &&
    -s "$SELFSTEAL_DIR/html/index.html" ]]
}
selfsteal_value(){ sed -n "s/^$1=//p" "$SELFSTEAL_DIR/.env" | head -1 | tr -d '\r'; }
validate_existing_selfsteal(){
 [[ "$(selfsteal_value SELF_STEAL_DOMAIN)" == "$DOMAIN" ]] || { warn 'Домен существующего SelfSteal отличается от домена прокси'; return 1; }
 [[ "$(selfsteal_value SELF_STEAL_PORT)" == 9443 ]] || { warn 'Поддерживается существующий SelfSteal на порту 9443'; return 1; }
 local details source
 details=$(docker inspect -f '{{.State.Running}} {{.HostConfig.NetworkMode}} {{.Config.Image}}' caddy-selfsteal) || return 1
 [[ "$details" == 'true host '*caddy* ]] || { warn 'Нужен работающий штатный контейнер caddy-selfsteal с сетью host'; return 1; }
 source=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' caddy-selfsteal) || return 1
 [[ "$source" == "$(readlink -f "$SELFSTEAL_DIR/Caddyfile")" ]] || { warn 'Caddy использует другой Caddyfile'; return 1; }
 source=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/www/html"}}{{.Source}}{{end}}{{end}}' caddy-selfsteal) || return 1
 [[ "$source" == "$(readlink -f "$SELFSTEAL_DIR/html")" ]] || { warn 'Caddy использует другой каталог сайта'; return 1; }
 docker exec caddy-selfsteal caddy validate --config /etc/caddy/Caddyfile >/dev/null || return 1
}
selfsteal_owns_port(){
 local pid lines line
 pid=$(docker inspect -f '{{.State.Pid}}' caddy-selfsteal) || return 1
 [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
 lines=$(ss -H -ltnp "( sport = :$1 )") || return 1
 [[ -n "$lines" ]] || return 1
 while IFS= read -r line; do
  [[ "$line" == *"pid=$pid,"* ]] || return 1
 done <<< "$lines"
}
backup_existing_selfsteal(){
 [[ ! -f "$BASE/selfsteal-existing.json" ]] || return 0
 local destination="$BASE/backups/selfsteal-before-web-$(date +%Y%m%d-%H%M%S)-$$"
 mkdir -p "$destination"; chmod 700 "$destination"
 cp -a "$SELFSTEAL_DIR/." "$destination/" || return 1
 docker inspect caddy-selfsteal > "$destination/container.json" || return 1
 python3 "$APP/lib/selfsteal_existing.py" "$BASE" "$destination" || return 1
 info "SelfSteal найден: установка сайта пропущена; резервная копия: $destination"
}
configure_existing_volumes(){
 python3 "$APP/lib/selfsteal_existing.py" "$BASE" --compose
}
handoff_existing_selfsteal(){
 [[ -f "$BASE/selfsteal-existing.json" && ! -f "$BASE/.selfsteal-handoff" ]] || return 0
 # The images are already built. Only now release the existing container's ports/name.
 docker stop caddy-selfsteal || return 1
 docker rm caddy-selfsteal || return 1
 touch "$BASE/.selfsteal-handoff"
}
rollback_existing_selfsteal(){
 [[ -f "$BASE/selfsteal-existing.json" && ! -f "$BASE/.installed" ]] || return 0
 local destination
 destination=$(python3 "$APP/lib/selfsteal_existing.py" "$BASE" --backup) || return 1
 if [[ -f "$BASE/.selfsteal-handoff" ]]; then compose down || return 1; fi
 cp -a "$destination/Caddyfile" "$SELFSTEAL_DIR/Caddyfile" || return 1
 # Remove the generated symlink before restoring the original Compose file.
 rm -f "$SELFSTEAL_DIR/docker-compose.yml"
 cp -a "$destination/docker-compose.yml" "$SELFSTEAL_DIR/docker-compose.yml" || return 1
 docker compose --project-directory "$SELFSTEAL_DIR" -f "$SELFSTEAL_DIR/docker-compose.yml" up -d || return 1
 rm -f "$BASE/.selfsteal-handoff" "$BASE/.selfsteal" "$BASE/compose.yaml" "$BASE/selfsteal-existing.json"
 warn 'Исходный SelfSteal восстановлен. Резервная копия сохранена.'
}
