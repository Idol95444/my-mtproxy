#!/bin/bash
# После обновления серта tg1.limbossh.date: nginx подхватывает файлы, telemt перечитывает конфиг (SIGHUP, без обрыва сессий).
systemctl reload nginx 2>/dev/null || true
systemctl reload telemt 2>/dev/null || true
