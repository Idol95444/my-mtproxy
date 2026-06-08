# my-mtproxy

MTProto-прокси для Telegram на базе **telemt** (Rust, client_mss=tspu).  
Обходит российский DPI/ТСПУ 2026. Управление через TUI-меню.

## Быстрый деплой

```bash
git clone https://github.com/limbo-wh/my-mtproxy.git
cd my-mtproxy
sudo bash manage.sh
```

После первого запуска команда доступна глобально:
```bash
sudo proxy
```

## Меню

```
1)  Проверить домен           DNS, IP, порт 443
2)  Установить прокси         telemt + systemd
3)  Настроить безопасность    ufw, fail2ban, keepalive, rate-limit

4)  Статус сервиса
5)  Логи telemt               live, Ctrl+C — выход
6)  Перезапустить
7)  Остановить
8)  Запустить
9)  Показать ссылку

10) Обновить систему
11) Обновить скрипт из git
12) Установить команду proxy
13) Удалить прокси
14) Проверить связь с Telegram
15) Обновить telemt
```

## Требования

- Ubuntu 22.04+ / Debian 12, root
- Домен с A-записью на VPS
- Открытый TCP 443

## Файлы

| Файл | Описание |
|---|---|
| `manage.sh` | TUI-менеджер |
| `telemt.toml.template` | Шаблон конфига telemt |
| `.env` | Секреты: DOMAIN, BASE_SECRET, TLS_DOMAIN (не в git) |
