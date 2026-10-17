#!/usr/bin/env python3
"""Uploads App/Website to the web host over FTPS, in ONE session.

curl logs in again for the next file after every error, and after a few
logins the host blocks the account with a 530 (protection against password
guessing). This script logs in exactly once. A file that fails with a 4xx is
retried in the same session after a pause. If the login fails, the script
aborts immediately so the block does not get longer.
Credentials come from the keychain; the password is stored in no file.

  website-upload.py                     upload everything
  website-upload.py --trocken           only list, no login
  website-upload.py --nur-geaendert     only files whose content changed since
                                           the last successful upload; under blog/
                                           locally deleted files are also deleted
                                           on the server. Nothing to do = no login.
  website-upload.py --nur blog/ sitemap.xml llms.txt
                                           only these paths (folders end with /)

Never uploaded: Markdown sources (blog/quellen/, seiten/quellen/, *.md,
DESIGN.md), hidden files and folders (.impeccable, .DS_Store) except
.htaccess. The root .htaccess does not replace the server file: only the
block "# BEGIN swiftly-blog ... # END swiftly-blog" is inserted, everything
else in it (e.g. the HTTPS redirect) stays.
"""
import ftplib, hashlib, io, json, os, re, subprocess, sys, time

SERVER = "w0198283.kasserver.com"
FOLDER = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Website"))
STATE = os.path.expanduser("~/Library/Application Support/swiftly-website/hochgeladen.json")
EXCEPTION_FOLDER = {"blog/quellen", "seiten/quellen"}
LOESCHBAR = "blog/"          # the script may only delete on the server here


def excluded(rel):
    teile = rel.split("/")
    if any(t.startswith(".") and t != ".htaccess" for t in teile):
        return True
    if any(rel == o or rel.startswith(o + "/") for o in EXCEPTION_FOLDER):
        return True
    return rel.endswith(".md")


def files():
    out = []
    for root, folder, names in os.walk(FOLDER):
        rel_root = os.path.relpath(root, FOLDER).replace(os.sep, "/")
        rel_root = "" if rel_root == "." else rel_root + "/"
        folder[:] = sorted(o for o in folder if not excluded(rel_root + o))
        for n in names:
            rel = rel_root + n
            if not excluded(rel):
                out.append(rel)
    return sorted(out)


def checksum(rel):
    h = hashlib.sha256()
    with open(os.path.join(FOLDER, rel), "rb") as d:
        for brocken in iter(lambda: d.read(1 << 20), b""):
            h.update(brocken)
    return h.hexdigest()


def state_read():
    try:
        with open(STATE) as h:
            return json.load(h)
    except (OSError, ValueError):
        return {}


def state_write(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as h:
        json.dump(state, h, indent=1, sort_keys=True)
    os.replace(tmp, STATE)


def access():
    def sec(*a):
        return subprocess.run(["security", "find-internet-password", "-s", SERVER, "-r", "ftp ", *a],
                              capture_output=True, text=True).stdout
    user = next((z.split("=", 1)[1].strip().strip('"') for z in sec().splitlines() if '"acct"' in z), "")
    password = sec("-w").strip()
    if not user or not password:
        sys.exit("Kein FTP-Eintrag im Schluesselbund.")
    return user, password


def htaccess_merge(ftp, f, local):
    """Root .htaccess: read the server file, replace or append our block."""
    if f != ".htaccess":
        return local
    alt = bytearray()
    try:
        ftp.retrbinary("RETR .htaccess", alt.extend)
    except ftplib.error_perm:
        pass                                   # no file on the server yet
    rest = re.sub(r"\n?# BEGIN swiftly-blog.*?# END swiftly-blog\n?", "\n",
                  alt.decode("utf-8", "replace"), flags=re.S).strip()
    if rest:
        print(f"      .htaccess: vorhandene Server-Regeln ({len(rest)} Zeichen) bleiben erhalten", flush=True)
    return ((rest + "\n\n") if rest else "").encode() + local.strip() + b"\n"


def arguments():
    args = sys.argv[1:]
    only = []
    if "--nur" in args:
        i = args.index("--nur") + 1
        while i < len(args) and not args[i].startswith("--"):
            only.append(args[i].lstrip("/"))
            i += 1
        if not only:
            sys.exit("--nur ohne Pfade.")
    return "--trocken" in args, "--nur-geaendert" in args, only


def fits(rel, only):
    return not only or any(rel == p or (p.endswith("/") and rel.startswith(p)) for p in only)


def main():
    trocken, changed, only = arguments()
    state = state_read()
    all = [f for f in files() if fits(f, only)]
    summen = {f: checksum(f) for f in all} if changed else {}
    list = [f for f in all if not changed or state.get(f) != summen[f]]
    distance = []
    if changed:
        available = set(files())
        distance = sorted(f for f in state if f.startswith(LOESCHBAR) and fits(f, only) and f not in available)

    if trocken:
        print(f"Wuerde {len(list)} Dateien laden" + (f" und {len(distance)} loeschen" if distance else "") + ":")
        [print("  " + f) for f in list]
        [print("  loeschen " + f) for f in distance]
        return
    if not list and not distance:
        print("Nichts geaendert, keine Anmeldung.")
        return

    user, password = access()
    try:
        ftp = ftplib.FTP_TLS(SERVER, timeout=60)
    except (EOFError, OSError) as e:
        password = None
        sys.exit(f"Server hat die Verbindung vor der Anmeldung geschlossen ({type(e).__name__}). "
                 "Meist eine Sperre nach zu vielen Anmeldungen. Kein weiterer Versuch.")
    try:
        ftp.login(user, password)
    except ftplib.error_perm as e:
        sys.exit(f"Anmeldung abgelehnt ({e}). Abbruch, damit die Sperre nicht laenger wird.")
    finally:
        password = None
    ftp.prot_p()
    root = ftp.pwd()

    created = set()
    error = []

    def folder_create(rel_folder):
        """One level at a time, from the root. A 550 usually means "already
        exists"; a cwd shows whether the folder is really there."""
        teile = [t for t in rel_folder.split("/") if t]
        for t in range(1, len(teile) + 1):
            path = "/".join(teile[:t])
            if path in created:
                continue
            try:
                ftp.mkd(path)
                print(f"      Ordner {path}/ angelegt", flush=True)
            except ftplib.error_perm:
                ftp.cwd(path)            # raises if it is missing and cannot be created
                ftp.cwd(root)
            created.add(path)

    try:
        for i, f in enumerate(list, 1):
            with open(os.path.join(FOLDER, f), "rb") as h:
                content = h.read()
            try:
                if "/" in f:
                    folder_create(f.rsplit("/", 1)[0])
                content = htaccess_merge(ftp, f, content)
                size = len(content)
                for attempt in range(1, 5):
                    try:
                        ftp.storbinary(f"STOR {f}", io.BytesIO(content))
                        live = ftp.size(f)
                        if live != size:
                            raise ftplib.error_temp(f"450 Groesse {live} statt {size}")
                        print(f"[{i:2}/{len(list)}] ok  {f}  {size} B", flush=True)
                        state[f] = summen.get(f) or checksum(f)
                        break
                    except ftplib.error_temp as e:
                        print(f"[{i:2}/{len(list)}] {e} - neuer Versuch in {attempt*10}s", flush=True)
                        time.sleep(attempt * 10)
                else:
                    error.append(f)
            except ftplib.error_perm as e:
                print(f"[{i:2}/{len(list)}] abgelehnt {f}: {e}", flush=True)
                error.append(f)

        for f in distance:
            try:
                ftp.delete(f)
                print(f"geloescht  {f}", flush=True)
            except ftplib.error_perm as e:
                if not str(e).startswith("550"):
                    print(f"loeschen abgelehnt {f}: {e}", flush=True)
                    error.append(f)
                    continue
            state.pop(f, None)
            folder = f.rsplit("/", 1)[0]
            try:
                ftp.rmd(folder)                   # only works if empty; otherwise ignored
                print(f"geloescht  {folder}/", flush=True)
            except ftplib.error_perm:
                pass
        ftp.quit()
    finally:
        state_write(state)

    print(f"Fertig: {len(list)-len([f for f in error if f in list])} von {len(list)} Dateien"
          + (f", {len(distance)} geloescht" if distance else "") + "."
          + (f" Fehlgeschlagen: {error}" if error else ""))
    sys.exit(1 if error else 0)


if __name__ == "__main__":
    main()
