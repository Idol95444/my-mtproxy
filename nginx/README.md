# TLS-фронт для telemt (mask -> 127.0.0.1:8443)

Шаблоны конфигов nginx, стоящих на сервере. `__TLS_DOMAIN__` — собственный домен-маска
(`tls_domain` в telemt.toml). Нужен пакет `libnginx-mod-stream`.

- `telemt-front.conf.template` -> `/etc/nginx/stream.d/telemt-front.conf`; в `nginx.conf`
  должен быть блок `stream { include /etc/nginx/stream.d/*.conf; }`.
- `vhosts.template` -> `/etc/nginx/sites-available/tg-front` (+ симлинк в sites-enabled).
- `certbot-deploy-hook.sh` -> `/etc/letsencrypt/renewal-hooks/deploy/`.

Сертификат: `certbot certonly --webroot -w /var/www/html -d __TLS_DOMAIN__`
(дефолтный сайт nginx на :80 остаётся — он отдаёт `.well-known` для продления).

Проверка: `openssl s_client -connect 127.0.0.1:8443 -servername <SNI>` для своего домена
показывает свой сертификат, для старых масок — сертификат настоящего сайта, для чужого
SNI — alert `unrecognized_name`. Тот же результат должен быть и на :443 прокси.
