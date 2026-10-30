#!/usr/bin/env python3
"""Baut ein webOS-IPK aus ./app ohne ares-cli.

IPK = ar-Archiv mit debian-binary, control.tar.gz, data.tar.gz
(App liegt unter usr/palm/applications/<id>/). Erzeugt vorher Icons + Splash.
"""
import hashlib, io, json, os, sys, tarfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_icons

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")
DIST = os.path.join(ROOT, "dist")


# ---------- IPK
def tar_gz(entries):
    """entries: Liste (arcname, bytes|None für Ordner, mode)"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tf:
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.mtime = int(time.time())
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mode = mode
            if data is None:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def ar(files):
    out = b"!<arch>\n"
    for name, data in files:
        hdr = "%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (name, int(time.time()), 0, 0, "100644", len(data))
        out += hdr.encode() + data
        if len(data) % 2:
            out += b"\n"
    return out


def main():
    make_icons.main()
    info = json.load(open(os.path.join(APP, "appinfo.json")))
    app_id, version = info["id"], info["version"]
    import re
    js_ver = re.search(r"APP_VERSION = '([^']+)'", open(os.path.join(APP, "js", "util.js"), encoding="utf-8").read())
    if not js_ver or js_ver.group(1) != version:
        sys.exit("Version passt nicht: appinfo.json %s, util.js APP_VERSION %s" % (version, js_ver and js_ver.group(1)))
    base = "usr/palm/applications/%s" % app_id

    entries, dirs, size = [], set(), 0
    def add_dir(d):
        parts = d.split("/")
        for i in range(1, len(parts) + 1):
            p = "/".join(parts[:i])
            if p and p not in dirs:
                dirs.add(p)
                entries.append(("./" + p + "/", None, 0o755))
    add_dir(base)
    for dp, dn, fn in os.walk(APP):
        dn.sort()
        rel = os.path.relpath(dp, APP).replace(os.sep, "/")
        target = base if rel == "." else base + "/" + rel
        add_dir(target)
        for f in sorted(fn):
            if f.startswith("."):
                continue
            data = open(os.path.join(dp, f), "rb").read()
            size += len(data)
            entries.append(("./" + target + "/" + f, data, 0o644))

    # Hintergrunddienst für das iPhone (tonalo.service) und die Paketbeschreibung, die App und Dienst verbindet
    services = []
    svc_dir = os.path.join(ROOT, "service")
    if os.path.isdir(svc_dir):
        svc = json.load(open(os.path.join(svc_dir, "services.json")))["id"]
        services.append(svc)
        add_dir("usr/palm/services/" + svc)
        for f in sorted(os.listdir(svc_dir)):
            if f.startswith("."):
                continue
            data = open(os.path.join(svc_dir, f), "rb").read()
            size += len(data)
            entries.append(("./usr/palm/services/%s/%s" % (svc, f), data, 0o644))
    add_dir("usr/palm/packages/" + app_id)
    pkg = {"id": app_id, "version": version, "app": app_id, "services": services}
    entries.append(("./usr/palm/packages/%s/packageinfo.json" % app_id, json.dumps(pkg).encode(), 0o644))

    control = (
        "Package: %s\nVersion: %s\nSection: misc\nPriority: optional\nArchitecture: all\n"
        "Installed-Size: %d\nMaintainer: %s\nDescription: %s\nwebOS-Package-Format-Version: 2\n"
        "webOS-Packager-Version: x.y.x\n" % (app_id, version, (size + 1023) // 1024, info.get("vendor", "dev"), info["title"])
    ).encode()

    ipk = ar([
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", tar_gz([("./", None, 0o755), ("./control", control, 0o644)])),
        ("data.tar.gz", tar_gz(entries)),
    ])
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, "%s_%s_all.ipk" % (app_id, version))
    with open(out, "wb") as f:
        f.write(ipk)
    print("OK:", out, "(%d KB)" % (len(ipk) // 1024))

    # Manifest für den Homebrew Channel (ipkUrl relativ -> funktioniert mit releases/latest/download/)
    repo = os.environ.get("GITHUB_REPOSITORY", "Wzkiie/tonalo")
    manifest = {
        "id": app_id,
        "version": version,
        "type": info.get("type", "web"),
        "title": info["title"],
        "appDescription": "Inoffizieller Navidrome-/Subsonic-Client für LG webOS-Fernseher",
        "iconUri": "https://raw.githubusercontent.com/%s/main/assets/icon-512.png" % repo,
        "sourceUrl": "https://github.com/%s" % repo,
        "rootRequired": False,
        "ipkUrl": os.path.basename(out),
        "ipkSize": len(ipk),
        "ipkHash": {"sha256": hashlib.sha256(ipk).hexdigest()},
    }
    mpath = os.path.join(DIST, "%s.manifest.json" % app_id)
    with open(mpath, "w") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print("OK:", mpath)


if __name__ == "__main__":
    sys.exit(main())
