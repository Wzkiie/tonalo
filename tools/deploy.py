#!/usr/bin/env python3
"""Baut das IPK und installiert es auf dem gerooteten LG-TV über Telnet (Homebrew Channel, Port 23).

Ablauf: Mac stellt das IPK kurz per HTTP im LAN bereit -> TV lädt es mit curl
-> Installation über luna://com.webos.appInstallService/dev/install -> App starten.

Nutzung: python3 tools/deploy.py <TV-IP>     (oder Umgebungsvariable TONALO_TV)
"""
import functools, hashlib, http.server, json, os, socket, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TV = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("TONALO_TV", "")
if not TV:
    sys.exit("Nutzung: python3 tools/deploy.py <TV-IP>")
PORT = 8091
IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


def tv(cmd, timeout=60):
    """Befehl per Telnet auf dem TV ausführen, Ausgabe zurückgeben."""
    s = socket.create_connection((TV, 23), timeout=10)
    s.settimeout(1)

    def strip(data):
        out, i = bytearray(), 0
        while i < len(data):
            b = data[i]
            if b == IAC and i + 1 < len(data):
                op = data[i + 1]
                if op in (DO, DONT, WILL, WONT) and i + 2 < len(data):
                    s.sendall(bytes([IAC, WONT if op in (DO, DONT) else DONT, data[i + 2]]))
                    i += 3; continue
                if op == SB:
                    j = data.find(bytes([IAC, SE]), i)
                    i = (j + 2) if j >= 0 else len(data); continue
                i += 2; continue
            out.append(b); i += 1
        return out.decode("utf-8", "replace")

    def read(sec, until=None):
        buf, t0 = "", time.time()
        while time.time() - t0 < sec:
            try:
                d = s.recv(65536)
                if not d: break
                buf += strip(d)
                if until and until in buf: break
            except socket.timeout:
                if not until: break
        return buf

    read(2)
    s.sendall((cmd + '; echo __ND_""DONE__\n').encode())
    out = read(timeout, until="__ND_DONE__\r\n")
    s.close()
    lines = out.replace("\r", "").split("\n")
    # Befehls-Echo bis zur Marker-Zeile überspringen
    start = next((i + 1 for i, l in enumerate(lines) if 'DONE__' in l and '""' in l), 0)
    return "\n".join(l for l in lines[start:] if "__ND_DONE__" not in l and not l.strip().endswith("#")).strip()


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((TV, 9)); return s.getsockname()[0]
    finally:
        s.close()


def main():
    subprocess.check_call([sys.executable, os.path.join(ROOT, "tools", "build_ipk.py")])
    info = json.load(open(os.path.join(ROOT, "app", "appinfo.json")))
    app_id, name = info["id"], "%s_%s_all.ipk" % (info["id"], info["version"])
    path = os.path.join(ROOT, "dist", name)
    digest = hashlib.md5(open(path, "rb").read()).hexdigest()

    try:
        socket.create_connection((TV, 23), timeout=5).close()
    except OSError:
        sys.exit("TV %s nicht per Telnet (Port 23) erreichbar – Homebrew Channel aktiv?" % TV)

    ip = lan_ip()
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=os.path.dirname(path))
    handler.log_message = lambda *a: None
    srv = http.server.ThreadingHTTPServer((ip, PORT), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        print("→ TV lädt %s von %s …" % (name, ip))
        out = tv("curl -s -m 60 -o /tmp/nd.ipk http://%s:%d/%s && md5sum /tmp/nd.ipk" % (ip, PORT, name), 90)
        if digest not in out:
            sys.exit("Download fehlgeschlagen:\n" + out)
        print("→ Installiere …")
        out = tv("luna-send-pub -w 60000 -i 'luna://com.webos.appInstallService/dev/install' "
                 "'{\"id\":\"%s\",\"ipkUrl\":\"/tmp/nd.ipk\",\"subscribe\":true}' 2>&1 | "
                 "grep -oE '\"state\":\"[^\"]*\"|\"errorText\":\"[^\"]*\"' | tail -1; rm -f /tmp/nd.ipk" % app_id, 90)
        print("  ", out)
        if "installed" not in out:
            sys.exit("Installation fehlgeschlagen.")
    finally:
        srv.shutdown()

    print("→ Starte App")
    tv("luna-send-pub -n 1 'luna://com.webos.applicationManager/launch' '{\"id\":\"%s\"}'" % app_id, 20)
    out = tv("luna-send -n 1 'luna://com.webos.applicationManager/getAppInfo' '{\"id\":\"%s\"}' | grep -oE '\"version\":\"[^\"]*\"'" % app_id, 20)
    print("Fertig – installiert:", out)


if __name__ == "__main__":
    main()
