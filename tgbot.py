#!/usr/bin/env python3
"""
MTProxy Telegram Bot
Команды: /stats /users /adduser <name> /link <user> /quota <user> <gb> /block <ip> /help
Безопасность: отвечает только chat_id из BOT_CHAT_ID в .env
"""
import json, os, sys, time, secrets, subprocess, urllib.request, urllib.parse

# ── Config ───────────────────────────────────────────────────────────────────

ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")

def load_env():
    env = {}
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return env

def get_cfg():
    cfg = load_env()
    return cfg

cfg = get_cfg()
BOT_TOKEN = cfg.get("BOT_TOKEN", "")
CHAT_IDS  = {c.strip() for c in cfg.get("BOT_CHAT_ID", "").split(",") if c.strip()}
API_PORT  = cfg.get("PROXY_API_PORT", "9091")

if not BOT_TOKEN:
    print("ОШИБКА: BOT_TOKEN не задан в .env", file=sys.stderr)
    sys.exit(1)

TG_URL    = f"https://api.telegram.org/bot{BOT_TOKEN}"
PROXY_API = f"http://127.0.0.1:{API_PORT}"

# ── Telegram helpers ──────────────────────────────────────────────────────────

def tg(method, **params):
    data = urllib.parse.urlencode(params).encode()
    try:
        with urllib.request.urlopen(f"{TG_URL}/{method}", data=data, timeout=35) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"tg/{method} error: {e}", file=sys.stderr)
        return {}

def send(chat_id, text):
    tg("sendMessage", chat_id=chat_id, text=text,
       parse_mode="HTML", disable_web_page_preview="true")

def get_updates(offset):
    r = tg("getUpdates", offset=offset, timeout=30, allowed_updates="message")
    return r.get("result", [])

# ── telemt API helpers ────────────────────────────────────────────────────────

def api_get(path):
    try:
        with urllib.request.urlopen(f"{PROXY_API}{path}", timeout=5) as r:
            return json.loads(r.read())
    except Exception:
        return {}

def api_request(method, path, payload=None):
    req = urllib.request.Request(
        f"{PROXY_API}{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    except Exception:
        return {}

# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_stats(chat_id, _args):
    d = api_get("/v1/users")
    if not d.get("ok"):
        send(chat_id, "❌ telemt API недоступен — сервис запущен?")
        return
    users = d["data"]
    conn  = sum(u.get("current_connections", 0) for u in users)
    ips   = sum(u.get("active_unique_ips", 0) for u in users)
    rec   = sum(u.get("recent_unique_ips", 0) for u in users)
    gb    = sum(u.get("total_octets", 0) for u in users) / 1024**3
    send(chat_id,
         f"📊 <b>Статистика MTProxy</b>\n\n"
         f"Соединений:       <b>{conn}</b>\n"
         f"Уникальных IP:    <b>{ips}</b>\n"
         f"Активных недавно: <b>{rec}</b>\n"
         f"Трафик всего:     <b>{gb:.2f} ГБ</b>")

def cmd_users(chat_id, _args):
    d = api_get("/v1/users")
    if not d.get("ok"):
        send(chat_id, "❌ telemt API недоступен"); return
    lines = ["👥 <b>Пользователи</b>\n"]
    for u in d["data"]:
        icon  = "✅" if u.get("enabled", True) else "🚫"
        gb    = u.get("total_octets", 0) / 1024**3
        conn  = u.get("current_connections", 0)
        ips   = u.get("active_unique_ips", 0)
        quota = u.get("data_quota_bytes")
        exp   = (u.get("expiration_rfc3339") or "")[:10]
        extra = ""
        if quota: extra += f" | лимит:{quota/1024**3:.0f}ГБ"
        if exp:   extra += f" | до:{exp}"
        lines.append(f"{icon} <b>{u['username']}</b> — {conn} соед, {ips} IP, {gb:.2f}ГБ{extra}")
    send(chat_id, "\n".join(lines))

def cmd_adduser(chat_id, args):
    if not args:
        send(chat_id, "Использование: /adduser &lt;имя&gt;"); return
    name   = args[0]
    secret = secrets.token_hex(16)

    r = api_request("POST", "/v1/users", {"username": name, "secret": secret})
    if not r.get("ok"):
        # fallback: edit toml + restart
        toml = cfg.get("TELEMT_CONF", "/etc/telemt/telemt.toml")
        try:
            with open(toml) as f:
                content = f.read()
            if f'{name} = ' in content:
                send(chat_id, f"❌ Пользователь {name} уже существует"); return
            if "[access.users]" in content:
                content = content.replace("[access.users]",
                                          f"[access.users]\n{name} = \"{secret}\"", 1)
            else:
                content += f'\n[access.users]\n{name} = "{secret}"\n'
            with open(toml, "w") as f:
                f.write(content)
            subprocess.run(["systemctl", "restart", "telemt"], check=True, capture_output=True)
            time.sleep(3)
        except Exception as e:
            send(chat_id, f"❌ Ошибка при создании: {e}"); return

    c = get_cfg()
    domain  = c.get("DOMAIN", "?")
    tls_dom = c.get("TLS_DOMAIN", "")
    hex_mask = tls_dom.encode().hex()
    port = c.get("PROXY_PORT", "443")
    link_ee = f"https://t.me/proxy?server={domain}&port={port}&secret=ee{secret}{hex_mask}"
    link_dd = f"https://t.me/proxy?server={domain}&port={port}&secret=dd{secret}"
    send(chat_id,
         f"✅ Пользователь <b>{name}</b> создан\n\n"
         f"<b>FakeTLS (основная):</b>\n<code>{link_ee}</code>\n\n"
         f"<b>dd (резерв):</b>\n<code>{link_dd}</code>")

def cmd_link(chat_id, args):
    if not args:
        send(chat_id, "Использование: /link &lt;пользователь&gt;"); return
    name = args[0]
    d = api_get("/v1/users")
    if not d.get("ok"):
        send(chat_id, "❌ API недоступен"); return
    u = next((x for x in d["data"] if x["username"] == name), None)
    if not u:
        send(chat_id, f"❌ Пользователь {name} не найден"); return
    tls    = u.get("links", {}).get("tls", [])
    secure = u.get("links", {}).get("secure", [])
    ee = (tls[0]    if tls    else "—").replace("tg://proxy?", "https://t.me/proxy?")
    dd = (secure[0] if secure else "—").replace("tg://proxy?", "https://t.me/proxy?")
    send(chat_id,
         f"🔗 <b>Ссылки {name}</b>\n\n"
         f"<b>FakeTLS:</b>\n<code>{ee}</code>\n\n"
         f"<b>dd:</b>\n<code>{dd}</code>")

def cmd_quota(chat_id, args):
    if len(args) < 2:
        send(chat_id, "Использование: /quota &lt;user&gt; &lt;ГБ&gt;  (0 = снять лимит)"); return
    name = args[0]
    try:
        gb = float(args[1])
    except ValueError:
        send(chat_id, "❌ Укажи число ГБ"); return
    payload = {"data_quota_bytes": int(gb * 1024**3)} if gb > 0 else {"data_quota_bytes": None}
    r = api_request("PATCH", f"/v1/users/{name}", payload)
    if r.get("ok"):
        msg = f"квота {gb:.0f} ГБ установлена" if gb > 0 else "лимит снят"
        send(chat_id, f"✅ {name}: {msg}")
    else:
        send(chat_id, f"❌ Ошибка API: {r}")

def cmd_disable(chat_id, args):
    if not args:
        send(chat_id, "Использование: /disable &lt;user&gt;"); return
    name = args[0]
    r = api_request("PATCH", f"/v1/users/{name}", {"enabled": False})
    if r.get("ok"):
        send(chat_id, f"🚫 Пользователь {name} отключён")
    else:
        send(chat_id, f"❌ Ошибка: {r}")

def cmd_enable(chat_id, args):
    if not args:
        send(chat_id, "Использование: /enable &lt;user&gt;"); return
    name = args[0]
    r = api_request("PATCH", f"/v1/users/{name}", {"enabled": True})
    if r.get("ok"):
        send(chat_id, f"✅ Пользователь {name} включён")
    else:
        send(chat_id, f"❌ Ошибка: {r}")

def cmd_block(chat_id, args):
    if not args:
        send(chat_id, "Использование: /block &lt;IP&gt;"); return
    ip = args[0]
    parts = ip.split(".")
    if len(parts) != 4 or not all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
        send(chat_id, "❌ Неверный формат IP"); return
    try:
        subprocess.run(["iptables", "-I", "INPUT", "-s", ip, "-j", "DROP"],
                       check=True, capture_output=True)
        send(chat_id, f"🚫 IP {ip} заблокирован")
    except subprocess.CalledProcessError as e:
        send(chat_id, f"❌ iptables: {e.stderr.decode().strip()}")

def cmd_help(chat_id, _args):
    send(chat_id,
         "📖 <b>MTProxy Bot — команды</b>\n\n"
         "/stats — статистика прокси\n"
         "/users — список пользователей\n"
         "/adduser &lt;имя&gt; — добавить пользователя\n"
         "/link &lt;user&gt; — ссылки пользователя\n"
         "/quota &lt;user&gt; &lt;ГБ&gt; — квота (0 = снять)\n"
         "/enable &lt;user&gt; — включить пользователя\n"
         "/disable &lt;user&gt; — отключить пользователя\n"
         "/block &lt;IP&gt; — заблокировать IP через iptables\n"
         "/help — эта справка")

COMMANDS = {
    "stats":   cmd_stats,
    "users":   cmd_users,
    "adduser": cmd_adduser,
    "link":    cmd_link,
    "quota":   cmd_quota,
    "enable":  cmd_enable,
    "disable": cmd_disable,
    "block":   cmd_block,
    "help":    cmd_help,
    "start":   cmd_help,
}

# ── Main loop ─────────────────────────────────────────────────────────────────

def handle(update):
    msg     = update.get("message", {})
    text    = (msg.get("text") or "").strip()
    chat_id = str(msg.get("chat", {}).get("id", ""))
    if not text.startswith("/") or not chat_id:
        return
    if CHAT_IDS and chat_id not in CHAT_IDS:
        send(chat_id, "⛔ Нет доступа"); return
    parts   = text.split()
    cmd     = parts[0].lstrip("/").split("@")[0].lower()
    args    = parts[1:]
    handler = COMMANDS.get(cmd)
    if handler:
        try:
            handler(chat_id, args)
        except Exception as e:
            send(chat_id, f"❌ Внутренняя ошибка: {e}")
    else:
        send(chat_id, "Неизвестная команда. /help — список команд")

def main():
    print(f"MTProxy bot started | chats: {CHAT_IDS or 'ALL (небезопасно!)'}", flush=True)
    offset = 0
    while True:
        try:
            updates = get_updates(offset)
        except Exception as e:
            print(f"getUpdates: {e}", file=sys.stderr, flush=True)
            time.sleep(5)
            continue
        for upd in updates:
            offset = upd["update_id"] + 1
            try:
                handle(upd)
            except Exception as e:
                print(f"handle: {e}", file=sys.stderr, flush=True)

if __name__ == "__main__":
    main()
