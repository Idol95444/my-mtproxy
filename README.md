# my-mtproxy

Деплой MTProto-прокси с FakeTLS одной командой (Caddy + alexbers).

## Быстрый деплой

```bash
# На свежем VPS (Ubuntu 22.04+ / Debian 12, под root):
git clone git@github.com:YOUR_USERNAME/my-mtproxy.git
cd my-mtproxy
bash deploy.sh
```

Скрипт спросит:
- **DOMAIN** — твой домен с A-записью на этот VPS
- **BASE_SECRET** — 32 hex-символа (`head -c 16 /dev/urandom | xxd -ps`)
- **AD_TAG** — необязательно, получить в @MTProxybot через `/newproxy`

## Что делает скрипт

1. Устанавливает Docker если его нет
2. Клонирует [alexbers/mtprotoproxy](https://github.com/alexbers/mtprotoproxy) (ветка stable)
3. Генерирует `Caddyfile` и `config.py` из шаблонов
4. Запускает Caddy (порты 80/443, получает LE-сертификат)
5. Запускает alexbers (порт 853, FakeTLS)
6. Печатает готовую FakeTLS-ссылку для раздачи

## Архитектура

```
Интернет -> :80  -> Caddy (автопродление LE-сертификата, редирект HTTP→HTTPS)
         -> :443 -> Caddy (TLS, страница-заглушка "OK", маскировка под nginx)
         -> :853 -> alexbers (FakeTLS, забирает сертификат с Caddy при старте)
```

## Файлы

| Файл | Назначение |
|---|---|
| `deploy.sh` | Интерактивный установщик |
| `Caddyfile.template` | Конфиг Caddy с плейсхолдером `__DOMAIN__` |
| `config.py.template` | Конфиг alexbers с плейсхолдерами |
| `docker-compose.yml` | Оба сервиса |
| `docs/V4.md` | Полная инструкция с решением проблем |
| `harden.sh` | Защита VPS (файрвол, fail2ban, автообновления) |

## Безопасность VPS

После деплоя рекомендуется запустить скрипт защиты:
```bash
bash harden.sh
```

Что он настроит:
- **Файрвол (ufw)** — открыты только порты 22, 80, 443, 853
- **fail2ban** — бан IP на 1 час после 3 неудачных SSH-попыток
- **Автообновления** — security-патчи ставятся автоматически
- **Сетевая защита** — sysctl против спуфинга, SYN-flood, MITM

## Безопасность репозитория

**Никогда не коммить**: `config.py`, `.env`, `caddy_data/`, `src/` — всё в `.gitignore`.

## Полная инструкция

Смотри [docs/V4.md](docs/V4.md) — подробный гайд с диагностикой проблем.

