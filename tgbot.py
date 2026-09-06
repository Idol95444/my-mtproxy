#!/usr/bin/env python3
"""
MTProxy Telegram Bot с inline-кнопками.
Команды: /start /stats /users /adduser /link /quota /block /help
Кнопки: навигация, управление пользователями, квоты, удаление с подтверждением.
"""
import json, os, re, sys, time, secrets, subprocess, urllib.request, urllib.parse

ENV_FILE   = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
AUDIT_LOG  = "/var/log/telemt-audit.jsonl"

# ── Config ────────────────────────────────────────────────────────────────────

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

_pub_ip_cache = {"ip": None, "ts": 0.0}

def get_link_host(env):
    """Хост для ссылок: DOMAIN из .env, а в бездоменном режиме — публичный IP VPS."""
    domain = env.get("DOMAIN", "")
    if domain:
        return domain
    if _pub_ip_cache["ip"] and time.time() - _pub_ip_cache["ts"] < 600:
        return _pub_ip_cache["ip"]
    for url in ("https://api.ipify.org", "https://ifconfig.me", "https://icanhazip.com"):
        try:
            ip = urllib.request.urlopen(url, timeout=5).read().decode().strip()
            if re.fullmatch(r"[0-9.]+", ip):
                _pub_ip_cache.update(ip=ip, ts=time.time())
                return ip
        except Exception:
            pass
    return "?"

# ── Несколько IP: определение, привязка пользователей ────────────────────────

HOSTS_MAP = "/opt/telemt/user-hosts.json"

# Приватные/служебные диапазоны, которые никогда не раздаём в ссылках.
_PRIVATE_RE = re.compile(
    r"^(?:0\.|10\.|127\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.|192\.168\.|"
    r"22[4-9]\.|2[3-5]\d\.)")

_hosts_cache = {"list": [], "ts": 0.0}

def primary_host():
    """Основной хост: домен, иначе PRIMARY_HOST из .env, иначе автоопределение."""
    c = load_env()
    if c.get("DOMAIN"):
        return c["DOMAIN"]
    return (c.get("PRIMARY_HOST") or "").strip() or get_link_host(c)

def detect_hosts():
    """Публичные IPv4 сервера, основной первым. В доменном режиме — только домен."""
    c = load_env()
    if c.get("DOMAIN"):
        return [c["DOMAIN"]]
    now = time.time()
    if _hosts_cache["list"] and now - _hosts_cache["ts"] < 60:
        found = list(_hosts_cache["list"])
    else:
        found = []
        try:
            r = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"],
                               capture_output=True, text=True, timeout=5)
            for line in r.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 4:
                    ip = parts[3].split("/")[0]
                    if not _PRIVATE_RE.match(ip):
                        found.append(ip)
        except Exception:
            pass
        found = sorted(set(found))
        _hosts_cache.update(list=found, ts=now)
    primary = primary_host()
    if primary in found:
        found.remove(primary)
    return ([primary] if primary else []) + found

def load_host_map():
    try:
        with open(HOSTS_MAP) as f:
            m = json.load(f)
        return m if isinstance(m, dict) else {}
    except Exception:
        return {}

def save_host_map(m):
    try:
        os.makedirs(os.path.dirname(HOSTS_MAP), exist_ok=True)
        tmp = HOSTS_MAP + ".tmp"
        with open(tmp, "w") as f:
            json.dump(m, f, indent=2, ensure_ascii=False)
        os.replace(tmp, HOSTS_MAP)
        return True
    except Exception:
        return False

def user_host(name):
    """IP, закреплённый за пользователем. Если такого IP на сервере уже нет — основной."""
    h = load_host_map().get(name)
    return h if h and h in detect_hosts() else primary_host()

def set_user_host(name, host):
    """Привязка к основному не хранится: такой юзер сам переезжает при смене основного IP."""
    m = load_host_map()
    if host == primary_host():
        m.pop(name, None)
    else:
        m[name] = host
    return save_host_map(m)

def forget_user_host(name):
    m = load_host_map()
    if m.pop(name, None) is not None:
        save_host_map(m)

def make_links(secret, host, c=None):
    c        = c or load_env()
    port     = c.get("PROXY_PORT", "443")
    hex_mask = c.get("TLS_DOMAIN", "").encode().hex()
    ee = f"https://t.me/proxy?server={host}&port={port}&secret=ee{secret}{hex_mask}"
    dd = f"https://t.me/proxy?server={host}&port={port}&secret=dd{secret}"
    return ee, dd

# ── Доступность IP из РФ (check-host.net) ────────────────────────────────────

RU_NODES  = ("ru2.node.check-host.net", "ru3.node.check-host.net")
# check-host.net отдаёт 403 на дефолтный User-Agent urllib — нужен браузерный.
CH_HEADERS = {"Accept": "application/json", "User-Agent": "Mozilla/5.0"}
_ru_cache = {"data": {}, "ts": 0.0}

def check_ru_reachability(hosts, port="443", ttl=300):
    """{ip: {'ru2': True/False, ...}}. Пустой словарь у IP = проверить не удалось."""
    now = time.time()
    if (_ru_cache["data"] and now - _ru_cache["ts"] < ttl
            and set(hosts) <= set(_ru_cache["data"])):
        return _ru_cache["data"]
    rids = {}
    for h in hosts:
        q = urllib.parse.urlencode(
            [("host", f"{h}:{port}")] + [("node", n) for n in RU_NODES])
        try:
            req = urllib.request.Request("https://check-host.net/check-tcp?" + q,
                                         headers=CH_HEADERS)
            with urllib.request.urlopen(req, timeout=10) as r:
                rids[h] = json.load(r).get("request_id")
        except Exception:
            rids[h] = None
    time.sleep(12)   # узлам нужно время на попытку подключения
    result = {}
    for h, rid in rids.items():
        result[h] = {}
        if not rid:
            continue
        try:
            req = urllib.request.Request(f"https://check-host.net/check-result/{rid}",
                                         headers=CH_HEADERS)
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.load(r)
        except Exception:
            continue
        for node, val in (data or {}).items():
            if not val:
                continue
            result[h][node.split(".")[0]] = any(
                isinstance(i, dict) and "time" in i for i in val if i)
    _ru_cache.update(data=result, ts=now)
    return result

cfg       = load_env()
BOT_TOKEN = cfg.get("BOT_TOKEN", "")
CHAT_IDS  = {c.strip() for c in cfg.get("BOT_CHAT_ID", "").split(",") if c.strip()}
API_PORT  = cfg.get("PROXY_API_PORT", "9091")

if not BOT_TOKEN:
    print("ОШИБКА: BOT_TOKEN не задан в .env", file=sys.stderr)
    sys.exit(1)

TG_URL    = f"https://api.telegram.org/bot{BOT_TOKEN}"
PROXY_API = f"http://127.0.0.1:{API_PORT}"

# ── Telegram helpers ──────────────────────────────────────────────────────────

def _tg_json(method, payload):
    req = urllib.request.Request(
        f"{TG_URL}/{method}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=35) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        # 400 при editMessageText = текст не изменился, это не ошибка
        if not (method == "editMessageText" and e.code == 400):
            print(f"tg/{method}: {e}", file=sys.stderr)
        return {}
    except Exception as e:
        print(f"tg/{method}: {e}", file=sys.stderr)
        return {}

def send(chat_id, text, markup=None):
    payload = {"chat_id": chat_id, "text": text,
               "parse_mode": "HTML", "disable_web_page_preview": True}
    if markup:
        payload["reply_markup"] = markup
    return _tg_json("sendMessage", payload)

def edit(chat_id, msg_id, text, markup=None):
    payload = {"chat_id": chat_id, "message_id": msg_id, "text": text,
               "parse_mode": "HTML", "disable_web_page_preview": True}
    if markup:
        payload["reply_markup"] = markup
    return _tg_json("editMessageText", payload)

def answer_cb(cb_id, text=""):
    _tg_json("answerCallbackQuery", {"callback_query_id": cb_id, "text": text})

def get_updates(offset):
    payload = {"offset": offset, "timeout": 30,
               "allowed_updates": ["message", "callback_query"]}
    req = urllib.request.Request(
        f"{TG_URL}/getUpdates",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=35) as r:
            return json.loads(r.read()).get("result", [])
    except Exception as e:
        print(f"getUpdates: {e}", file=sys.stderr)
        return []

# ── Keyboard builders ─────────────────────────────────────────────────────────

def kb(*rows):
    """kb( [(text,data), ...], [(text,data), ...] ) → InlineKeyboardMarkup dict"""
    return {"inline_keyboard": [
        [{"text": t, "callback_data": d} for t, d in row]
        for row in rows
    ]}

def kb_main():
    return kb(
        [("📊 Статистика", "stats"),   ("👥 Пользователи", "users")],
        [("🖥 Мониторинг",  "monitor"), ("⚙️ Управление",   "mgmt_hint")],
        [("🌐 IP-адреса",   "ips")],
    )

def kb_stats():
    return kb(
        [("🔄 Обновить", "stats"), ("👥 Пользователи", "users")],
        [("◀️ Главная",  "main")],
    )

def kb_users(users):
    rows = []
    for u in users:
        name    = u["username"]
        enabled = u.get("enabled", True)
        icon    = "✅" if enabled else "🚫"
        rows.append([
            (f"{icon} {name}", f"user_detail:{name}"),
            ("🔗",              f"user_link:{name}"),
            ("🚫" if enabled else "✅", f"user_toggle:{name}"),
        ])
    rows.append([("➕ Добавить",    "user_add_hint"),
                 ("🔄 Обновить",   "users")])
    rows.append([("◀️ Главная",    "main")])
    return kb(*rows)

def kb_user_detail(name, enabled):
    toggle_label = "🚫 Выключить" if enabled else "✅ Включить"
    return kb(
        [("🔗 Ссылка",      f"user_link:{name}"),
         (toggle_label,      f"user_toggle:{name}")],
        [("📊 5 ГБ",        f"quota:{name}:5"),
         ("📊 10 ГБ",       f"quota:{name}:10"),
         ("📊 20 ГБ",       f"quota:{name}:20")],
        [("♾ Снять квоту",  f"quota:{name}:0"),
         ("🗑 Удалить",      f"user_del:{name}")],
        [("🌐 Сменить IP",  f"hostpick:{name}")],
        [("◀️ Пользователи", "users")],
    )

def kb_monitor():
    return kb(
        [("🔄 Обновить", "monitor")],
        [("◀️ Главная",  "main")],
    )

def kb_host_pick(name, action, back="users"):
    primary = primary_host()
    rows = [[(("⭐ " if h == primary else "") + h, f"{action}:{name}:{h}")]
            for h in detect_hosts()]
    rows.append([("◀️ Отмена", back)])
    return kb(*rows)

def kb_confirm_del(name):
    return kb(
        [("❌ Да, удалить",  f"user_del_ok:{name}"),
         ("↩ Отмена",        f"user_detail:{name}")],
    )

# ── Накопленный трафик (с учётом рестартов telemt) ───────────────────────────

def get_traffic_offsets():
    """
    Читает аудит-лог и возвращает накопленные байты предыдущих сессий на юзера.
    Каждый рестарт telemt обнуляет total_octets → находим падения и суммируем пики.
    Формула в боте: offsets[user] + current_api_octets = реальный накопленный трафик.
    """
    try:
        with open(AUDIT_LOG) as f:
            lines = f.readlines()
    except OSError:
        return {}
    acc   = {}   # имя → накоплено из завершённых сессий
    prev  = {}   # имя → значение в прошлом снапшоте
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            snap = json.loads(line)
        except json.JSONDecodeError:
            continue
        for u in snap.get("data", []):
            name = u.get("username", "")
            cur  = u.get("total_octets", 0)
            if name not in acc:
                acc[name] = 0
                prev[name] = 0
            # рестарт: счётчик упал → добавляем максимум завершённой сессии
            if cur < prev[name]:
                acc[name] += prev[name]
            prev[name] = cur
    return acc

# ── telemt API ────────────────────────────────────────────────────────────────

def api_get(path):
    try:
        with urllib.request.urlopen(f"{PROXY_API}{path}", timeout=5) as r:
            return json.loads(r.read())
    except Exception:
        return {}

def api_call(method, path, payload=None):
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

# ── Content builders (текст + кнопки) ────────────────────────────────────────

def build_stats():
    d = api_get("/v1/users")
    if not d.get("ok"):
        return "❌ telemt API недоступен — сервис запущен?", None
    users   = d["data"]
    offsets = get_traffic_offsets()
    conn = sum(u.get("current_connections", 0) for u in users)
    ips  = sum(u.get("active_unique_ips", 0)   for u in users)
    rec  = sum(u.get("recent_unique_ips", 0)   for u in users)
    gb   = sum(offsets.get(u["username"], 0) + u.get("total_octets", 0) for u in users) / 1024**3
    return (
        f"📊 <b>Статистика MTProxy</b>\n\n"
        f"Соединений:       <b>{conn}</b>\n"
        f"Уникальных IP:    <b>{ips}</b>\n"
        f"Активных недавно: <b>{rec}</b>\n"
        f"Трафик всего:     <b>{gb:.2f} ГБ</b>"
    ), kb_stats()

def build_users():
    d = api_get("/v1/users")
    if not d.get("ok"):
        return "❌ telemt API недоступен", None
    users   = d["data"]
    offsets = get_traffic_offsets()
    lines = ["👥 <b>Пользователи</b>\n"]
    for u in users:
        icon  = "✅" if u.get("enabled", True) else "🚫"
        gb    = (offsets.get(u["username"], 0) + u.get("total_octets", 0)) / 1024**3
        conn  = u.get("current_connections", 0)
        ips   = u.get("active_unique_ips", 0)
        quota = u.get("data_quota_bytes")
        exp   = (u.get("expiration_rfc3339") or "")[:10]
        extra = (f" | лимит:{quota/1024**3:.0f}ГБ" if quota else "") + \
                (f" | до:{exp}" if exp else "")
        lines.append(f"{icon} <b>{u['username']}</b> — {conn} соед, {ips} IP, {gb:.2f}ГБ{extra}")
    lines.append("\nВыбери пользователя ↓")
    return "\n".join(lines), kb_users(users)

def build_user_detail(name):
    d = api_get("/v1/users")
    if not d.get("ok"):
        return "❌ API недоступен", None
    u = next((x for x in d["data"] if x["username"] == name), None)
    if not u:
        return f"❌ Пользователь {name} не найден", None
    enabled = u.get("enabled", True)
    offsets = get_traffic_offsets()
    gb    = (offsets.get(name, 0) + u.get("total_octets", 0)) / 1024**3
    conn  = u.get("current_connections", 0)
    ips   = u.get("active_unique_ips", 0)
    quota = u.get("data_quota_bytes")
    exp   = (u.get("expiration_rfc3339") or "")[:10] or "—"
    return (
        f"👤 <b>{name}</b>\n\n"
        f"Статус:     {'✅ включён' if enabled else '🚫 выключен'}\n"
        f"Соединений: {conn}\n"
        f"Уник. IP:   {ips}\n"
        f"Трафик:     {gb:.2f} ГБ\n"
        f"Квота:      {f'{quota/1024**3:.0f} ГБ' if quota else 'без лимита'}\n"
        f"Действует:  до {exp}\n"
        f"IP выдачи:  {user_host(name)}"
        + ("  ⭐" if user_host(name) == primary_host() else "")
    ), kb_user_detail(name, enabled)

def build_ips():
    hosts   = detect_hosts()
    primary = primary_host()
    if not hosts:
        return "❌ Не удалось определить ни одного публичного IP", kb([("◀️ Главная", "main")])

    d     = api_get("/v1/users")
    users = d.get("data", []) if d.get("ok") else []
    by_host = {}
    for u in users:
        by_host.setdefault(user_host(u["username"]), []).append(u["username"])

    ru    = check_ru_reachability(hosts)
    parts = ["🌐 <b>IP-адреса сервера</b>"]
    for h in hosts:
        per = ru.get(h, {})
        ok  = sorted(n for n, v in per.items() if v)
        bad = sorted(n for n, v in per.items() if not v)
        if not per:
            status = "❔ проверить не удалось"
        elif not bad:
            status = f"✅ из РФ отвечает ({', '.join(ok)})"
        elif not ok:
            status = f"⛔️ из РФ НЕ отвечает ({', '.join(bad)}) — похоже на бан ТСПУ"
        else:
            status = f"⚠️ частично: ок {', '.join(ok)}, таймаут {', '.join(bad)}"
        who = by_host.get(h, [])
        block = (f"<b>{h}</b>{' ⭐ основной' if h == primary else ''}\n"
                 f"  {status}\n"
                 f"  Пользователей: {len(who)}")
        if who:
            block += "\n  " + ", ".join(who[:10]) + ("…" if len(who) > 10 else "")
        parts.append(block)
    parts.append("<i>Проверка через check-host.net: ru2 — Москва, ru3 — СПб.\n"
                 "Результат кэшируется на 5 минут.</i>")
    return "\n\n".join(parts), kb([("🔄 Обновить", "ips")], [("◀️ Главная", "main")])

def build_user_links(name):
    c = load_env()

    d = api_get("/v1/users")
    if not d.get("ok"):
        return "❌ API недоступен", None
    u = next((x for x in d["data"] if x["username"] == name), None)
    if not u:
        return f"❌ Пользователь {name} не найден", None

    tls_links = u.get("links", {}).get("tls", [])
    if not tls_links:
        return f"❌ Нет TLS-ссылки для {name}", None
    s      = tls_links[0].split("secret=")[-1]
    secret = s[2:34] if s[:2] in ("ee", "dd") else s[:32]

    host   = user_host(name)
    ee, dd = make_links(secret, host, c)
    mark   = " ⭐ основной" if host == primary_host() else ""
    return (
        f"🔗 <b>Ссылки {name}</b>\n"
        f"IP: <b>{host}</b>{mark}\n\n"
        f"<b>FakeTLS (основная):</b>\n<code>{ee}</code>\n\n"
        f"<b>dd (резерв):</b>\n<code>{dd}</code>"
    ), kb([("🌐 Сменить IP", f"hostpick:{name}")],
          [("◀️ Назад",      f"user_detail:{name}")])

def build_monitor():
    lines = ["🖥 <b>Мониторинг сервера</b>\n"]

    # RAM и Swap
    try:
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mem[k.strip()] = int(v.split()[0])
        total  = mem["MemTotal"]    // 1024
        avail  = mem["MemAvailable"] // 1024
        used   = total - avail
        swap_t = mem.get("SwapTotal", 0) // 1024
        swap_u = (mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)) // 1024
        lines.append(f"💾 RAM: {used} / {total} MB  (свободно {avail} MB)")
        if swap_t > 0:
            lines.append(f"   Swap: {swap_u} / {swap_t} MB")
    except Exception:
        lines.append("💾 RAM: недоступно")

    # Диск
    try:
        r = subprocess.run(
            ["df", "/", "--output=size,used,pcent"],
            capture_output=True, text=True, timeout=3,
        )
        row = r.stdout.strip().splitlines()
        if len(row) >= 2:
            size_kb, used_kb, pct = row[1].split()
            lines.append(
                f"💽 Диск: {pct} ({int(used_kb)/1024**2:.1f} / {int(size_kb)/1024**2:.1f} GB)"
            )
    except Exception:
        lines.append("💽 Диск: недоступно")

    # CPU load average
    try:
        with open("/proc/loadavg") as f:
            la = f.read().split()
        lines.append(f"📈 CPU load: {la[0]}  {la[1]}  {la[2]}")
    except Exception:
        pass

    # Аптайм
    try:
        with open("/proc/uptime") as f:
            secs = float(f.read().split()[0])
        d = int(secs // 86400)
        h = int((secs % 86400) // 3600)
        m = int((secs % 3600) // 60)
        parts = []
        if d: parts.append(f"{d}д")
        if h: parts.append(f"{h}ч")
        parts.append(f"{m}м")
        lines.append(f"⏱ Аптайм: {' '.join(parts)}")
    except Exception:
        pass

    lines.append("")

    # Состояние telemt
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "telemt"],
            capture_output=True, text=True, timeout=3,
        )
        st = r.stdout.strip()
        lines.append(f"🔄 telemt: {'✅' if st == 'active' else '🔴'} {st}")
    except Exception:
        lines.append("🔄 telemt: ❓")

    d = api_get("/v1/users")
    if d.get("ok"):
        users = d["data"]
        conn  = sum(u.get("current_connections", 0) for u in users)
        ips   = sum(u.get("active_unique_ips",   0) for u in users)
        lines.append(f"   Соединений: {conn}  |  Уник. IP: {ips}")

    lines.append("")

    # fail2ban
    try:
        r = subprocess.run(
            ["fail2ban-client", "status", "sshd"],
            capture_output=True, text=True, timeout=5,
        )
        for line in r.stdout.splitlines():
            if "Currently banned" in line:
                num = line.split(":")[-1].strip()
                lines.append(f"🛡 fail2ban SSH: {num} IP заблокировано")
            elif "Banned IP list" in line:
                ips_str = line.split(":", 1)[-1].strip()
                if ips_str:
                    lines.append(f"   {ips_str[:80]}")
    except Exception:
        pass

    lines.append(f"\n🕐 {time.strftime('%H:%M:%S  %d.%m.%Y')}")
    return "\n".join(lines), kb_monitor()

# ── Callback router ───────────────────────────────────────────────────────────

def on_callback(cb_id, chat_id, msg_id, data):
    answer_cb(cb_id)

    if data == "main":
        edit(chat_id, msg_id, "📖 <b>MTProxy Bot</b>\nВыбери действие:", kb_main())

    elif data == "monitor":
        text, markup = build_monitor()
        edit(chat_id, msg_id, text, markup)

    elif data == "stats":
        text, markup = build_stats()
        edit(chat_id, msg_id, text, markup)

    elif data == "users":
        text, markup = build_users()
        edit(chat_id, msg_id, text, markup)

    elif data == "mgmt_hint":
        edit(chat_id, msg_id,
             "⚙️ <b>Управление</b>\n\nДля ввода данных используй команды:\n"
             "/adduser &lt;имя&gt; — добавить пользователя\n"
             "/quota &lt;user&gt; &lt;ГБ&gt; — квота\n"
             "/block &lt;IP&gt; — заблокировать IP",
             kb([("◀️ Назад", "main")]))

    elif data.startswith("user_detail:"):
        text, markup = build_user_detail(data.split(":", 1)[1])
        edit(chat_id, msg_id, text, markup)

    elif data.startswith("user_link:"):
        text, markup = build_user_links(data.split(":", 1)[1])
        edit(chat_id, msg_id, text, markup)

    elif data.startswith("user_toggle:"):
        name = data.split(":", 1)[1]
        d    = api_get("/v1/users")
        u    = next((x for x in d.get("data", []) if x["username"] == name), None)
        enabled = u.get("enabled", True) if u else True
        conns   = u.get("current_connections", 0) if u else 0
        # M3: выключение активного юзера кладёт клиентов в retry-шторм. Если есть
        # живые соединения — требуем подтверждение и советуем удаление вместо выключения.
        if enabled and conns > 0:
            edit(chat_id, msg_id,
                 f"⚠️ У <b>{name}</b> сейчас <b>{conns}</b> активных соединений.\n\n"
                 f"Выключение (не удаление) НЕ рвёт клиентов чисто — они уйдут в "
                 f"бесконечные переподключения, это нагружает сервер.\n"
                 f"Если юзер больше не нужен — лучше <b>удалить</b>.",
                 kb([("🚫 Всё равно выключить", f"user_disable_ok:{name}"),
                     ("🗑 Удалить",             f"user_del:{name}")],
                    [("↩ Отмена",               f"user_detail:{name}")]))
            return
        api_call("PATCH", f"/v1/users/{name}", {"enabled": not enabled})
        text, markup = build_user_detail(name)
        edit(chat_id, msg_id, text, markup)

    elif data.startswith("user_disable_ok:"):
        name = data.split(":", 1)[1]
        api_call("PATCH", f"/v1/users/{name}", {"enabled": False})
        text, markup = build_user_detail(name)
        edit(chat_id, msg_id, text, markup)

    elif data.startswith("quota:"):
        _, name, gb_str = data.split(":", 2)
        gb = float(gb_str)
        payload = {"data_quota_bytes": int(gb * 1024**3)} if gb > 0 else {"data_quota_bytes": None}
        api_call("PATCH", f"/v1/users/{name}", payload)
        text, markup = build_user_detail(name)
        edit(chat_id, msg_id, text, markup)

    elif data.startswith("user_del:"):
        name = data.split(":", 1)[1]
        edit(chat_id, msg_id,
             f"⚠️ Удалить <b>{name}</b>?\nЕго ссылка перестанет работать.",
             kb_confirm_del(name))

    elif data.startswith("user_del_ok:"):
        name = data.split(":", 1)[1]
        r = api_call("DELETE", f"/v1/users/{name}")
        # НЕ откатываемся на enabled:false при ошибке — выключенный (но не удалённый)
        # юзер кладёт клиентов в retry-шторм. telemt 3.4.15+ поддерживает DELETE.
        if not r.get("ok"):
            edit(chat_id, msg_id,
                 f"❌ Не удалось удалить <b>{name}</b> (API вернул ошибку).\n"
                 f"Юзер НЕ выключен, чтобы не вызвать шторм переподключений.",
                 kb([("◀️ Пользователи", "users")]))
            return
        forget_user_host(name)
        text, markup = build_users()
        edit(chat_id, msg_id, text, markup)

    elif data == "ips":
        text, markup = build_ips()
        edit(chat_id, msg_id, text, markup)

    elif data.startswith("addip:"):
        _, name, host = data.split(":", 2)
        text, markup = create_user(name, host)
        edit(chat_id, msg_id, text, markup)

    elif data.startswith("hostpick:"):
        name = data.split(":", 1)[1]
        edit(chat_id, msg_id, f"На каком IP выдать <b>{name}</b>?",
             kb_host_pick(name, "sethost", back=f"user_detail:{name}"))

    elif data.startswith("sethost:"):
        _, name, host = data.split(":", 2)
        set_user_host(name, host)
        text, markup = build_user_links(name)
        edit(chat_id, msg_id, text, markup)

    elif data == "user_add_hint":
        edit(chat_id, msg_id,
             "➕ Напиши:\n\n<code>/adduser имя</code>\n\n"
             "Если IP несколько — бот спросит, на каком выдать.\n"
             "Можно сразу: <code>/adduser имя 1.2.3.4</code>",
             kb([("◀️ Назад", "users")]))

# ── Text command handlers ─────────────────────────────────────────────────────

def cmd_start(chat_id, _):
    send(chat_id, "📖 <b>MTProxy Bot</b>\nВыбери действие:", kb_main())

def cmd_stats(chat_id, _):
    text, markup = build_stats()
    send(chat_id, text, markup)

def cmd_users(chat_id, _):
    text, markup = build_users()
    send(chat_id, text, markup)

def create_user(name, host):
    """Создаёт пользователя и закрепляет за ним IP. Возвращает (text, markup)."""
    if not re.match(r'^[a-zA-Z0-9_-]{1,32}$', name):
        return ("❌ Имя пользователя: только латиница, цифры, `-`, `_`, до 32 символов",
                kb([("◀️ Пользователи", "users")]))
    if host not in detect_hosts():
        return (f"❌ IP {host} на сервере не найден",
                kb([("◀️ Пользователи", "users")]))

    secret = secrets.token_hex(16)
    cfg    = load_env()
    ad_tag = cfg.get("AD_TAG") or None

    payload = {"username": name, "secret": secret}
    if ad_tag:
        payload["user_ad_tag"] = ad_tag

    r = api_call("POST", "/v1/users", payload)
    if not r.get("ok"):
        toml = cfg.get("TELEMT_CONF", "/etc/telemt/telemt.toml")
        try:
            with open(toml) as f: content = f.read()
            if f'{name} = ' in content:
                return (f"❌ Пользователь {name} уже существует",
                        kb([("◀️ Пользователи", "users")]))
            if "[access.users]" in content:
                content = content.replace("[access.users]",
                                          f"[access.users]\n{name} = \"{secret}\"", 1)
            else:
                content += f'\n[access.users]\n{name} = "{secret}"\n'
            if ad_tag:
                if "[access.user_ad_tags]" in content:
                    content = content.replace("[access.user_ad_tags]",
                                              f"[access.user_ad_tags]\n{name} = \"{ad_tag}\"", 1)
                else:
                    content += f'\n[access.user_ad_tags]\n{name} = "{ad_tag}"\n'
            with open(toml, "w") as f: f.write(content)
            subprocess.run(["systemctl", "restart", "telemt"],
                           check=True, capture_output=True)
            time.sleep(3)
        except Exception as e:
            return (f"❌ Ошибка: {e}", kb([("◀️ Пользователи", "users")]))

    set_user_host(name, host)
    ee, dd = make_links(secret, host)
    mark   = " ⭐ основной" if host == primary_host() else ""
    return (f"✅ <b>{name}</b> создан\n"
            f"IP: <b>{host}</b>{mark}\n\n"
            f"<b>FakeTLS:</b>\n<code>{ee}</code>\n\n"
            f"<b>dd:</b>\n<code>{dd}</code>",
            kb([("🌐 Сменить IP",   f"hostpick:{name}")],
                [("👥 Пользователи", "users")]))

def cmd_adduser(chat_id, args):
    if not args:
        send(chat_id, "Использование: /adduser &lt;имя&gt; [IP]"); return
    name  = args[0]
    hosts = detect_hosts()

    # IP задан прямо в команде
    if len(args) > 1:
        if args[1] not in hosts:
            send(chat_id, f"❌ IP <b>{args[1]}</b> на сервере не найден.\n"
                          f"Доступны: {', '.join(hosts) or '—'}"); return
        text, markup = create_user(name, args[1])
        send(chat_id, text, markup); return

    # Один хост — спрашивать нечего
    if len(hosts) < 2:
        text, markup = create_user(name, hosts[0] if hosts else primary_host())
        send(chat_id, text, markup); return

    if not re.match(r'^[a-zA-Z0-9_-]{1,32}$', name):
        send(chat_id, "❌ Имя пользователя: только латиница, цифры, `-`, `_`, до 32 символов"); return
    send(chat_id, f"На каком IP выдать <b>{name}</b>?", kb_host_pick(name, "addip"))

def cmd_ips(chat_id, _):
    text, markup = build_ips()
    send(chat_id, text, markup)

def cmd_link(chat_id, args):
    if not args:
        send(chat_id, "Использование: /link &lt;user&gt;"); return
    text, markup = build_user_links(args[0])
    send(chat_id, text, markup)

def cmd_quota(chat_id, args):
    if len(args) < 2:
        send(chat_id, "Использование: /quota &lt;user&gt; &lt;ГБ&gt;  (0 = снять)"); return
    name = args[0]
    try: gb = float(args[1])
    except ValueError:
        send(chat_id, "❌ Укажи число ГБ"); return
    payload = {"data_quota_bytes": int(gb * 1024**3)} if gb > 0 else {"data_quota_bytes": None}
    r = api_call("PATCH", f"/v1/users/{name}", payload)
    if r.get("ok"):
        msg = f"квота {gb:.0f} ГБ" if gb > 0 else "лимит снят"
        send(chat_id, f"✅ {name}: {msg}", kb([("👤 Детали", f"user_detail:{name}")]))
    else:
        send(chat_id, "❌ Ошибка API")

def cmd_block(chat_id, args):
    if not args:
        send(chat_id, "Использование: /block &lt;IP&gt;"); return
    ip    = args[0]
    parts = ip.split(".")
    if len(parts) != 4 or not all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
        send(chat_id, "❌ Неверный формат IP"); return
    try:
        subprocess.run(["iptables", "-I", "INPUT", "-s", ip, "-j", "DROP"],
                       check=True, capture_output=True)
        send(chat_id, f"🚫 IP {ip} заблокирован")
    except subprocess.CalledProcessError as e:
        send(chat_id, f"❌ iptables: {e.stderr.decode().strip()}")

def cmd_monitor(chat_id, _):
    text, markup = build_monitor()
    send(chat_id, text, markup)

def cmd_help(chat_id, _):
    send(chat_id,
         "📖 <b>MTProxy Bot — команды</b>\n\n"
         "/stats — статистика прокси\n"
         "/users — список пользователей\n"
         "/monitor — мониторинг сервера\n"
         "/adduser &lt;имя&gt; [IP] — добавить пользователя\n"
         "/link &lt;user&gt; — ссылки пользователя\n"
         "/ips — IP сервера и их доступность из РФ\n"
         "/quota &lt;user&gt; &lt;ГБ&gt; — квота (0 = снять)\n"
         "/block &lt;IP&gt; — заблокировать IP",
         kb_main())

COMMANDS = {
    "start":   cmd_start,
    "help":    cmd_help,
    "stats":   cmd_stats,
    "users":   cmd_users,
    "monitor": cmd_monitor,
    "adduser": cmd_adduser,
    "link":    cmd_link,
    "ips":     cmd_ips,
    "quota":   cmd_quota,
    "block":   cmd_block,
}

# ── Main loop ─────────────────────────────────────────────────────────────────

def handle_update(upd):
    if "callback_query" in upd:
        cb      = upd["callback_query"]
        cb_id   = cb["id"]
        chat_id = str(cb["message"]["chat"]["id"])
        msg_id  = cb["message"]["message_id"]
        data    = cb.get("data", "")
        if CHAT_IDS and chat_id not in CHAT_IDS:
            answer_cb(cb_id, "⛔ Нет доступа"); return
        try:
            on_callback(cb_id, chat_id, msg_id, data)
        except Exception as e:
            print(f"callback error: {e}", file=sys.stderr)
            answer_cb(cb_id, "❌ Ошибка")
        return

    msg     = upd.get("message", {})
    text    = (msg.get("text") or "").strip()
    chat_id = str(msg.get("chat", {}).get("id", ""))
    if not text or not chat_id or not text.startswith("/"):
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
            send(chat_id, f"❌ Ошибка: {e}")
    else:
        send(chat_id, "Неизвестная команда. /help — список команд", kb_main())

def main():
    print(f"MTProxy bot started | chats: {CHAT_IDS or 'ALL'}", flush=True)
    offset = 0
    while True:
        try:
            updates = get_updates(offset)
        except Exception as e:
            print(f"poll error: {e}", file=sys.stderr, flush=True)
            time.sleep(5)
            continue
        for upd in updates:
            offset = upd["update_id"] + 1
            try:
                handle_update(upd)
            except Exception as e:
                print(f"handle error: {e}", file=sys.stderr, flush=True)

if __name__ == "__main__":
    main()
