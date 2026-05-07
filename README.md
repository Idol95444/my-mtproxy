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

## Безопасность

**Никогда не коммить**: `config.py`, `.env`, `caddy_data/`, `src/` — всё в `.gitignore`.

## Полная инструкция

Смотри [docs/V4.md](docs/V4.md) — подробный гайд с диагностикой проблем.

## Если хочешь поделиться репозиторием

Репо безопасно для шаринга — в нём нет секретов, только шаблоны и скрипт.
Но перед тем как сделать репо публичным или дать доступ другим:

1. **Проверь историю коммитов** — убедись что в прошлых коммитах не было
   случайно добавленных `config.py` или `.env`:
   ```bash
   git log --all --full-history -- config.py .env
   ```
   Если что-то нашлось — не делай репо публичным, пересоздай с чистой историей.

2. **Замени `YOUR_USERNAME`** в этом README на username получателя,
   или используй HTTPS-ссылку для клонирования.

3. **Добавь коллаборатора** (если репо остаётся приватным):
   GitHub → Settings → Collaborators → Add people.

4. **Или форкни** — получатель делает fork, и у него своя копия.
