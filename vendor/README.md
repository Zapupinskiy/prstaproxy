# SelfSteal

`selfsteal.sh` — неизменённый исходник DigneZzZ/remnawave-scripts, версия 2.11.1.
Commit: `e18fae58f6f98727c682af023f2269fd434324a1`.
Источник: https://github.com/DigneZzZ/remnawave-scripts/blob/e18fae58f6f98727c682af023f2269fd434324a1/selfsteal.sh
Лицензия MIT сохранена в SELFSTEAL-LICENSE.

Адаптер `lib/selfsteal.sh` загружает определения функций без финального
диспетчера, использует штатные create_caddy_config/download_template,
randomize_template/setup_file_permissions и команды управления. Установка,
меню, обновление и управление Docker объединены с ПРОСТОВПН WEB PROXY.
`NODE_IP` при загрузке может быть передан после общей проверки DNS.
Upstream не скачивается и не исполняется заново при каждой установке.

Новая установка вызывает исходную install_command (FORCE_MODE, домен, порт 9443),
со штатным случайным выбором и загрузкой шаблона. Запуск отдельного Caddy
перехватывается адаптером и выполняется позднее в общем Compose стеке.
